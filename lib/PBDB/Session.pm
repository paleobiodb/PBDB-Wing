package PBDB::Session;

use strict;
use Digest::MD5;
# use CGI::Cookie;
use PBDB::Constants qw($WRITE_URL $IP_MAIN $IP_BACKUP makeAnchor);
use Dancer ();


# Create a new session record in response to a login.

sub start_login_session {
    
    my ($class, $session_id, $enterer_no, $authorizer_no, $login_role) = @_;
    
    # print STDERR "session_id = $session_id\n";
    # print STDERR "authorizer_no = $authorizer_no\n";
    # print STDERR "enterer_no = $enterer_no\n";
    # print STDERR "login_role = $login_role\n";
    
    my $dbh = PBDB::DBConnection::connect();
    
    unless ( $session_id && $session_id =~ qr{ ^ [0-9A-F-]+ $ }xs )
    {
	die "Error: invalid session_id\n";
    }
    
    unless ( $enterer_no && $enterer_no =~ qr{ ^ [0-9]+ $ }xs )
    {
	die "Error: invalid enterer_no\n";
    }
    
    unless ( $authorizer_no && $authorizer_no =~ qr{ ^ [0-9]+ $ }xs )
    {
	die "Error: invalid authorizer_no\n";
    }
    
    unless ( $login_role && $login_role =~ qr{ ^ (?: authorizer | enterer ) $ }xs )
    {
	die "Error: invalid role\n";
    }
    
    my $quoted_id = $dbh->quote($session_id);
    my $quoted_role = $dbh->quote($login_role);
    
    my $sql = "
	REPLACE INTO session_data (session_id, authorizer_no, enterer_no, role, record_date)
	VALUES ($quoted_id, $authorizer_no, $enterer_no, $quoted_role, now())";
    
    my $result = $dbh->do($sql);
    
    $sql = "
	UPDATE session_data as s join person as pa on pa.person_no = authorizer_no
		join person as pe on pe.person_no = enterer_no
	SET s.authorizer = pa.name,
	    s.enterer = pe.name,
	    s.superuser = pe.superuser,
	    s.roles = s.role
	WHERE session_id = $quoted_id";
    
    $result = $dbh->do($sql);
    
    my $a = 1;	# we can stop here when debugging
}


sub end_login_session {
    
    my ($class, $session_id) = @_;
    
    return unless $session_id;
    
    my $dbh = PBDB::DBConnection::connect();
    
    my $quoted_id = $dbh->quote($session_id);
    
    my $sql = "DELETE FROM session_data WHERE session_id = $quoted_id";
    
    my $result = $dbh->do($sql);
    
    my $a = 1;	# we can stop here when debugging
}


# Handles validation of the user
sub new {
    my ($class, $dbt, $session_id, $authorizer_no) = @_;
    my $dbh = $dbt->dbh;
    my $self;
    
    if ($session_id) {
	
	my $quoted_id = $dbh->quote($session_id);
	# Ensure their session_id corresponds to a valid database entry
	my $sql = "SELECT * FROM session_data WHERE session_id=$quoted_id LIMIT 1";
	my $sth = $dbh->prepare( $sql ) || die ( "$sql<hr>$!" );
	# execute returns number of rows affected for NON-select statements
	# and true/false (success) for select statements.
	$sth->execute();
        my $rs = $sth->fetchrow_hashref();
	
	if ( $authorizer_no && $rs && $rs->{authorizer_no} && $rs->{authorizer_no} ne $authorizer_no )
	{
	    print STDERR "UPDATING SESSION authorizer_no = $authorizer_no\n";
	    
	    $rs->{authorizer_no} = $authorizer_no;
	    
	    my ($authorizer_name) = $dbh->selectrow_array("SELECT real_name FROM pbdb_wing.users WHERE person_no = $authorizer_no");
	    
	    $rs->{authorizer} = $authorizer_name || 'unknown';
	    
	    my $quoted_name = $dbh->quote($rs->{authorizer});
	    
	    $dbh->do("UPDATE pbdb.session_data SET authorizer_no = $authorizer_no, authorizer = $quoted_name
			WHERE session_id = $quoted_id");
	}
	
        if($rs) {
            # Store some values (for later)
            foreach my $field ( keys %{$rs} ) {
                $self->{$field} = $rs->{$field};
            }
            # These are used in lots of places (anywhere with a 'Me' button), convenient to create here
            my $authorizer_reversed = $rs->{'authorizer'};
            $authorizer_reversed =~ s/^\s*([^\s]+)\s+([^\s]+)\s*$/$2, $1/;
            my $enterer_reversed = $rs->{'enterer'};
            $enterer_reversed =~ s/^\s*([^\s]+)\s+([^\s]+)\s*$/$2, $1/;
            $self->{'authorizer_reversed'} = $authorizer_reversed;
            $self->{'enterer_reversed'} = $enterer_reversed;    
	    $self->{role} = $rs->{role};
            # Update the person data
            # We don't bother for bristol mirror 
            if ($ENV{'SERVER_ADDR'} eq $IP_MAIN ||
                $ENV{'SERVER_ADDR'} eq $IP_BACKUP) {
                my $sql = "UPDATE person SET last_action=NOW() WHERE person_no=$self->{enterer_no}";
                $dbh->do( $sql ) || die ( "$sql<HR>$!" );
            }

            # now update the session_data record to the current time
            $sql = "UPDATE session_data SET record_date=NULL WHERE session_id=".$dbh->quote($session_id);
            $dbh->do($sql);
            $self->{'logged_in'} = 1;
        } else {
            $self->{'logged_in'} = 0;
        }
	} else {
        $self->{'logged_in'} = 0;
    }
    $self->{'dbt'} = $dbt;
    bless $self, $class;
    return $self;
}


# Processes the login from the submitted authorizer/enterer names.
# Creates a session_data table row if the login is valid.
#
# modified by rjp, 3/2004.
sub processLogin {
	my $self = shift;
	my $authorizer  = shift;
    my $enterer = shift;
    my $password = shift;

    my $dbt = $self->{'dbt'};
    my $dbh = $dbt->dbh;
    
	my $valid = 0;


	# First do some housekeeping
	# This cleans out ALL records in session_data older than 48 hours.
	$self->houseCleaning( $dbh );


	# We want them to specify both an authorizer and an enterer
	# otherwise kick them out to the public site.
	if (!$authorizer || !$enterer || !$password) {
		return '';
	}

	# also check that both names exist in the database.
	if (! Person::checkName($dbt,$enterer) || ! Person::checkName($dbt,$authorizer)) {
		return '';
	}

    my ($sql,@results,$authorizer_row,$enterer_row);
	# Get info from database on this authorizer.
	$sql =	"SELECT * FROM person WHERE name=".$dbh->quote($authorizer);
	@results =@{$dbt->getData($sql)};
	$authorizer_row  = $results[0];

	# Get info from database on this enterer.
	$sql =	"SELECT * FROM person WHERE name=".$dbh->quote($enterer);
	@results =@{$dbt->getData($sql)};
	$enterer_row  = $results[0];

	# find highest-level role JA 20.1.09
	# note that we are defaulting to lowest-level in cases where role
	#  is unknown, which is only true for people added before the
	#  student and technician categories were separated
	$enterer_row->{'roles'} = $enterer_row->{'role'};
	if ( $enterer_row->{'role'} =~ /authorizer/ )	{
		$enterer_row->{'role'} = "authorizer";
	} elsif ( $enterer_row->{'role'} =~ /technician/ )	{
		$enterer_row->{'role'} = "technician";
	} elsif ( $enterer_row->{'role'} =~ /student/ )	{
		$enterer_row->{'role'} = "student";
	} else	{
		$enterer_row->{'role'} = "limited";
	}
	

	if ($authorizer_row) {
		# Check the password
		my $db_password = $authorizer_row->{'password'};
		my $plaintext = $authorizer_row->{'plaintext'};
		if ( $enterer_row->{'password'} ne "" )	{
			$db_password = $enterer_row->{'password'};
		}
		if ( $enterer_row->{'plaintext'} ne "" )	{
			$plaintext = $enterer_row->{'plaintext'};
		}

		# First try the plain text version
		if ( $plaintext && $plaintext eq $password) {
			$valid = 1; 
			# If that worked but there is still an old encrypted password,
			#   zorch that version to make sure it is never used again
			#   JA 12.6.02
			if ($db_password ne "")	{
				$sql =	"UPDATE person SET password='' WHERE person_no = ".$authorizer_row->{'person_no'};
				$dbh->do( $sql ) || die ( "$sql<HR>$!" );
			}
		# If that didn't work and there is no plain text password,
		#   try the old encrypted password
		} elsif ($plaintext eq "") {
			# Legacy: Test the encrypted password
			# For encrypted passwords
			my $salt = substr ( $db_password, 0, 2);
			my $encryptedPassword = crypt ( $password, $salt );

			if ( $db_password eq $encryptedPassword ) {
				$valid = 1; 
				# Mysteriously collect their plaintext password
				$sql =	"UPDATE person SET password='',plaintext=".$dbh->quote($password).
						" WHERE person_no = ".$authorizer_row->{person_no};
				$dbh->do( $sql ) || die ( "$sql<HR>$!" );
			}
		}

		# If valid, do some stuff
		if ( $valid ) {
		    my $session_id = $self->buildSessionID();

#             my $cookie = new CGI::Cookie(
#                 -name    => 'session_id',
#                 -value   => $session_id, 
#                 -expires => '+1y',
#                 -path    => "/",
#                 -secure  => 0);

			# Store the session id (for later)
			$self->{session_id} = $session_id;

			# Are they superuser?
			my $superuser = 0;
			if ( $authorizer_row->{'superuser'} && 
                 $authorizer_row->{'role'} =~ /authorizer/ && 
                 $authorizer eq $enterer) {
                 $superuser = 1; 
            }

			# Insert all of the session data into a row in the session_data table
			# so we will still have access to it the next time the user tries to do something.
            my %row = ('session_id'=>$session_id,
                       'authorizer'=>$authorizer_row->{'name'},
                       'authorizer_no'=>$authorizer_row->{'person_no'},
                       'enterer'=>$enterer_row->{'name'},
                       'enterer_no'=>$enterer_row->{'person_no'},
                       'role'=>$enterer_row->{'role'},
                       'roles'=>$enterer_row->{'roles'},
                       'superuser'=>$superuser,
                       'marine_invertebrate'=>$authorizer_row->{'marine_invertebrate'}, 
                       'micropaleontology'=>$authorizer_row->{'micropaleontology'},
                       'paleobotany'=>$authorizer_row->{'paleobotany'},
                       'taphonomy'=>$authorizer_row->{'taphonomy'},
                       'vertebrate'=>$authorizer_row->{'vertebrate'});

            # Copy to the session objet
            while (my ($k,$v) = each %row) {
                $self->{$k} = $v;
            }
           
            my $keys = join(",",keys(%row));
            my $values = join(",",map { $dbh->quote($_) } values(%row));
            
			$sql =	"INSERT INTO session_data ($keys) VALUES ($values)";
			$dbh->do( $sql ) || die ( "$sql<HR>$!" );
	
		#	return $cookie;
		}
	}
	return "";
}


# Handles the Guest login.  No password required.
# Anyone who passes through this routine becomes guest.
sub processGuestLogin {
	my $self = shift;
    my $dbt = $self->{'dbt'};
    my $dbh = $dbt->dbh;
    my $name = shift;

    my $session_id = $self->buildSessionID();

#     my $cookie = new CGI::Cookie(
#         -name    => 'session_id',
#         -value   => $session_id
#         -expires => '+1y',
#         -domain  => '',
#         -path    => "/",
#         -secure  => 0);

    # Store the session id (for later)
    $self->{session_id} = $session_id;

    # The research groups are stored so as not to do many db lookups
    $self->{enterer_no} = 0;
    $self->{enterer} = $name;
    $self->{authorizer_no} = 0;
    $self->{authorizer} = $name;
    
    # Insert all of the session data into a row in the session_data table
    # so we will still have access to it the next time the user tries to do something.
    #
    my %row = ('session_id'=>$session_id,
               'authorizer'=>$self->{'authorizer'},
               'authorizer_no'=>$self->{'authorizer_no'},
               'enterer'=>$self->{'enterer'},
               'enterer_no'=>$self->{'enterer_no'});
   
    my $keys = join(",",keys(%row));
    my $values = join(",",map { $dbh->quote($_) } values(%row));
    
    my $sql = "INSERT INTO session_data ($keys) VALUES ($values)";
    $dbh->do( $sql ) || die ( "$sql<HR>$!" );

	#return $cookie;
}

sub buildSessionID {
  my $self = shift;
  my $md5 = Digest::MD5->new();
  my $remote = $ENV{REMOTE_ADDR} . $ENV{REMOTE_PORT};
  # Concatenates args: epoch, this interpreter PID, $remote (above)
  # returned as base 64 encoded string
  my $id = $md5->md5_base64(time, $$, $remote);
  # replace + with -, / with _, and = with .
  $id =~ tr|+/=|-_.|;
  return $id;
}

# Cleans stale entries from the session_data table.
# 48 hours is the current time considered
sub houseCleaning {
	my $self = shift;
    my $dbh = $self->{'dbt'}->dbh;

	# COULD ALSO USE 'DATE_SUB'
	my $sql = 	"DELETE FROM session_data ".
			" WHERE record_date < DATE_ADD( now(), INTERVAL -2 DAY)";
	$dbh->do( $sql ) || die ( "$sql<HR>$!" );

	# COULD ALSO USE 'DATE_SUB'
	# Nix the Guest users @ 1 day
	$sql = 	"DELETE FROM session_data ".
			" WHERE record_date < DATE_ADD( now(), INTERVAL -1 DAY) ".
			"	AND authorizer = 'Guest' ";
	$dbh->do( $sql ) || die ( "$sql<HR>$!" );
	1;
}

# Sets the reference_no
sub setReferenceNo {
    my ($self,$reference_no) = @_;
	my $dbh = $self->{'dbt'}->dbh;

	if ($reference_no =~ /^\d+$/) {
		my $sql =	"UPDATE session_data ".
				"	SET reference_no = $reference_no ".
				" WHERE session_id = ".$dbh->quote($self->get("session_id"));
		$dbh->do( $sql ) || die ( "$sql<HR>$!" );

		# Update our reference_no
		$self->{reference_no} = $reference_no;
	}
}

# A destination is used for procedural requests.  For 
# example, when requesting a ReID and you need to select
# a reference first.
sub enqueue {
    my ($self,$queue) = @_;
    my $dbh = $self->{dbt}->dbh;
	my $current_contents = "";

	# Get the current contents
	my $sql =	"SELECT queue ".
			"  FROM session_data ".
			" WHERE session_id = ".$dbh->quote($self->get("session_id"));
    my $sth = $dbh->prepare( $sql ) || die ( "$sql<hr>$!" );
    $sth->execute();

	if ( $sth->rows ) {
		my $rs = $sth->fetchrow_hashref ( );
		$current_contents = $rs->{queue};
	} 
	$sth->finish();

	# If there was something, tack it on the front of the queue
	if ( $current_contents ) { $queue = $queue."|".$current_contents; }

	$sql =	"UPDATE session_data ".
			" SET queue=".$dbh->quote($queue) .
			" WHERE session_id=".$dbh->quote($self->get("session_id"));
	$dbh->do( $sql ) || die ( "$sql<HR>$!" );
}

# Pulls an action off the queue
sub unqueue {
	my $self = shift;
	my $dbh = $self->{'dbt'}->dbh;

	my $sql =	"SELECT queue ".
			"  FROM session_data ".
			" WHERE session_id = ".$dbh->quote($self->get("session_id"));
    my $sth = $dbh->prepare( $sql ) || die ( "$sql<hr>$!" );
    $sth->execute();
	my $rs = $sth->fetchrow_hashref();
	$sth->finish();
	my $queue = $rs->{queue};

	my %hash = ();
	if ( $queue ) {

		# Split into separate commands
		my @entries = split ( /\|/, $queue );
		my $entry = shift ( @entries );

		# Write the rest out
		$queue = join ( "|", @entries );
		$sql =	"UPDATE session_data ".
				"	SET queue=".$dbh->quote($queue).
				" WHERE session_id=".$dbh->quote($self->{'session_id'});
		$dbh->do( $sql ) || die ( "$sql<HR>$!" );

		# Parse the entry.  Since it is any valid URL, use the CGI routine.
		# print STDERR "$entry\n";
		# my $cgi = CGI->new ( $entry );

		# # Return it as a hash
		# my @names = $cgi->param();
		# foreach my $field ( @names ) {
		# 	$hash{$field} = $cgi->param($field);
		# }
		
		my @params = split /&/, $entry;
		
		foreach my $p ( @params )
		{
		    if ( $p =~ /([^=])+=(.*)/ )
		    {
			$hash{$1} = $2;
		    }
		    
		    elsif ( $p )
		    {
			$hash{$1} = 1;
		    }
		}
		
		# Save entire line in case we want it
		$hash{'queue'} = $queue;
	} 

	return %hash;
}

sub clearQueue {
	my $self = shift;
    my $dbh = $self->{dbt}->dbh;

	my $sql =	"UPDATE session_data ".
			"	SET queue = NULL ".
			" WHERE session_id = ".$dbh->quote($self->{'session_id'});
	$dbh->do( $sql ) || die ( "$sql<HR>$!" );
}

# Gets a variable from memory
sub get {
	my $self = shift;
	my $key = shift;

	return $self->{$key};
}

# Is the current user superuser?  This is true
# if the authorizer is alroy and the enterer is alroy.  
sub isSuperUser {
	my $self = shift;
    return $self->{'superuser'};
}


# Tells if we are are logged in and a valid database member
sub isDBMember {
    my $self = shift;
    return 1 if $self->{role} eq 'authorizer' || $self->{role} eq 'enterer';
    return;
}

sub isGuest {
    my $self = shift;
    return (!$self->isDBMember());
}

# Display the preferences page JA 25.6.02
sub displayPreferencesPage {
    my ($dbt,$q,$s,$hbo) = @_;
    my $dbh = $dbt->dbh;
	my $select = "";
	my $destination = $q->param("destination");

	$s->enqueue("action=$destination" );

	my %pref = $s->getPreferences();

	my ($setFieldNames,$cleanSetFieldNames,$shownFormParts) = $s->getPrefFields();
	# Populate the form
	my @rowData;
	my @fieldNames = @{$setFieldNames};
	push @fieldNames , @{$shownFormParts};
	for my $f (@fieldNames)	{
		if ($pref{$f} ne "")	{
			push @rowData,$pref{$f};
		}
		else	{
			push @rowData,"";
		}
	}

	# Show the preferences entry page
	print $hbo->populateHTML('preferences', \@rowData, \@fieldNames);
}

# Get the current preferences JA 25.6.02
sub getPreferences	{
    my ($self,$person_no) = @_;
    if (!$person_no) {
        $person_no = $self->{enterer_no};
    }
    my $dbt = $self->{dbt};
    my $dbh = $dbt->dbh;

	my %pref;

	my $sql = "SELECT preferences FROM person WHERE person_no=".int($person_no);

	my $sth = $dbh->prepare( $sql ) || die ( "$sql<hr>$!" );
	$sth->execute();
	my @row = $sth->fetchrow_array();
	$sth->finish();
	my @prefvals = split / -:- /,$row[0];
	for my $p (@prefvals)	{
		if ($p =~ /=/)	{
			my ($a,$b) = split /=/,$p,2;
			$pref{$a} = $b;
		}
		else	{
			$pref{$p} = "yes";
		}
	}
	return %pref;
}

# Made a separate function JA 29.6.02
sub getPrefFields	{
    my ($self) = @_;
	# translations of fields in database tables, where needed
	my %cleanSetFieldNames = ("blanks" => "blank occurrence rows",
		"research_group" => "research group",
		"latdeg" => "latitude", "lngdeg" => "longitude",
		"geogscale" => "geographic resolution",
		"max_interval" => "time interval",
		"stratscale" => "stratigraphic resolution",
		"lithology1" => "primary lithology",
		"environment" => "paleoenvironment",
		"collection_type" => "collection purpose",
		"assembl_comps" => "assemblage components",
		"pres_mode" => "preservation mode",
		"coll_meth" => "collection type",
		"geogcomments" => "location details",
		"stratcomments" => "stratigraphic comments",
		"lithdescript" => "complete lithology description" );
	# list of fields in tables
	my @setFieldNames = ("blanks", "research_group", "license", "country", "state",
			"latdeg", "latdir", "lngdeg", "lngdir", "geogscale",
			"max_interval",
			"formation", "stratscale", "lithology1", "environment",
			"collection_type", "assembl_comps", "pres_mode", "coll_meth",
		# occurrence fields
			"species_name",
		# comments fields
			"geogcomments", "stratcomments", "lithdescript");
	for my $fn (@setFieldNames)	{
		if ($cleanSetFieldNames{$fn} eq "")	{
			my $cleanFN = $fn;
			$cleanFN =~ s/_/ /g;
			$cleanSetFieldNames{$fn} = $cleanFN;
		}
	}
	# options concerning display of forms, not individual fields
	my @shownFormParts = ("collection_search", "editable_collection_no",
		"genus_and_species_only", "taphonomy", "subgenera", "abundances",
		"plant_organs");
	return (\@setFieldNames,\%cleanSetFieldNames,\@shownFormParts);

}

# Set new preferences JA 25.6.02
sub setPreferences	{
    my ($dbt,$q,$s,$hbo) = @_;
    my $dbh_r = $dbt->dbh;

	print qq|<center><p class="large">Your current preferences</center>
<table align=center cellpadding=4 width="80%">
<tr><td>Displayed sections</td><td>Prefilled values</td></tr>
|;

	# assembl_comps: separate with commas
	my @formVals = $q->param('assembl_comps');
	# Zorch first cell (always a null value for some reason)
	shift @formVals;
	my $numSetValues = @formVals;
	if ( $numSetValues ) {
		$q->param(assembl_comps => join(',', @formVals) );
	}

	my ($setFieldNames,$cleanSetFieldNames,$shownFormParts) = $s->getPrefFields();
    my $pref_sql = "";
	for my $i (0..$#{$setFieldNames})	{
		my $f = ${$setFieldNames}[$i];
 		if ( $q->param($f))	{
			my $val = $q->param($f);
 			$pref_sql .= " -:- $f=".$val;
		}
	}

	if ($q->param("latdir"))	{
		$q->param(latdeg => $q->param("latdeg") . " " . $q->param("latdir") );
	}
	if ($q->param("lngdir"))	{
		$q->param(lngdeg => $q->param("lngdeg") . " " . $q->param("lngdir") );
	}

	print "<tr><td valign=\"top\" width=\"33%\" class=\"verysmall\">\n";
	for my $f (@{$shownFormParts})	{
		my $cleanName = $f;
		$cleanName =~ s/_/ /g;
 		if ( $q->param($f) )	{
 			$pref_sql .= " -:- " . $f;
			print "<i>Show</i> $cleanName<br>\n";
 		} else	{
			print "<i>Do not show</i> $cleanName<br>\n";
		}
	}
	# Are any comments stored?
	my $commentsStored;
	for my $i (0..$#{$setFieldNames})	{
		my $f = ${$setFieldNames}[$i];
		if ($q->param($f) && $f =~ /comm/)	{
			$commentsStored = 1;
		}
	}

	print "</td>\n<td valign=\"top\" width=\"33%\" class=\"verysmall\">\n";
	for my $i (0..$#{$setFieldNames})	{
		my $f = ${$setFieldNames}[$i];
		if ($f =~ /^geogcomments$/)	{
			print "</td></tr>\n<tr><td align=\"left\" colspan=3>\n";
			if ($commentsStored)	{
				print "<p class='medium'>Comment fields</p>\n";
 			}
 		}
		elsif ($f =~ /mapsize/)	{
			print qq|</td></tr>
<tr><td valign="top">Map view</td></tr>
<tr><td valign="top" class="verysmall">
|;
		}
		elsif ($f =~ /(formation)|(coastlinecolor)/)	{
			print "</td><td valign=\"top\" width=\"33%\" class=\"verysmall\">\n";
		}
 		if ( $q->param($f) && $f !~ /^eml/ && $f !~ /^l..dir$/)	{
			my @letts = split //,${$cleanSetFieldNames}{$f};
			$letts[0] =~ tr/[a-z]/[A-Z]/;
			print join '',@letts , " = <i>" . $q->param($f) . "</i><br>\n";
 		}
	}
	print "</td></tr></table>\n";
	$pref_sql =~ s/^ -:- //;

    my $enterer_no = $s->get('enterer_no');
    if ($enterer_no) {
     	my $sql = "UPDATE person SET preferences=".$dbh_r->quote($pref_sql)." WHERE person_no=$enterer_no";
        my $result = $dbh_r->do($sql);

	    print "<p>\n<center>" . makeAnchor("displayPreferencesPage", "", "Edit these preferences") . "</center>\n";
    	my %continue = $s->unqueue();
	    if($continue{action}){
		    print "<center><p>\n" . makeAnchor("$continue{action}", "", "<b>Continue</b>") . "<p></center>\n";
	    }
    }
}

1;
