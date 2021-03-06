#
# NexusfileWrite.pm
# 
# Created by Michael McClennen, 2013-01-31
# 
# The purpose of this module is to provide an interface for adding, deleting
# and altering the stored nexus files and their associated information.


package PBDB::Nexusfile;
use strict;

use PBDB::TaxonInfo;
use Carp qw(carp croak);
use Digest::MD5;

our ($SQL_STRING, $ERROR_STRING);



=head3 addFile ( dbt, filename, authorizer_no, enterer_no, options )

Add a new nexus file record using the given information.  If there is an
existing record with the same filename and authorizer_no, it will be updated.
Otherwise, a new record will be created.  In either case, the nexusfile_no is
returned.

If an error occurs, the return value is false.

Options include:

=over 4

=item notes

Store the specified string in the 'notes' field of the nexus file record.

=back

=cut

sub addFile {
    
    my ($dbt, $filename, $authorizer_no, $enterer_no, $options) = @_;
    
    my $dbh = $dbt->{dbh};
    my $result;
    
    $options ||= {};
    
    # Do some basic checking
    
    unless ( $filename =~ /\w/ )
    {
	$ERROR_STRING = "The filename must not be empty";
	return 0;
    }
    
    unless ( $authorizer_no > 0 )
    {
	$ERROR_STRING = "You must be logged in";
	return 0;
    }
    
    # First, see if there is already a matching record.
    
    my $dbh = $dbt->{dbh};
    my $quoted_name = $dbh->quote($filename);
    $authorizer_no =~ tr/0-9//dc;
    $enterer_no =~ tr/0-9//dc; $enterer_no += 0;
    
    $SQL_STRING = "
		SELECT nexusfile_no FROM nexus_files
		WHERE filename=$quoted_name and authorizer_no=$authorizer_no";
    
    my ($nexusfile_no) = $dbh->selectrow_array(encode_utf8($SQL_STRING));
    
    # If there is, then we update it.
    
    my $quoted_notes = $options->{notes} ? 
	$dbh->quote($options->{notes}) :
	    $dbh->quote('');
    
    if ( $nexusfile_no > 0 )
    {
	$SQL_STRING = "
		UPDATE nexus_files
		SET enterer_no=$enterer_no, notes=$quoted_notes, modified=now()
		WHERE nexusfile_no=$nexusfile_no";
	
	$result = $dbh->do(encode_utf8($SQL_STRING));
	
	if ( $result )
	{
	    return $nexusfile_no;
	}
	
	else
	{
	    $ERROR_STRING = "Update error A in NexusEdit.pm: nexusfile_no=$nexusfile_no, filename=$quoted_name, authorizer_no=$authorizer_no";
	    return 0;
	}
    }
    
    # Otherwise, we create a new record.
    
    else
    {
	$SQL_STRING = "
		INSERT INTO nexus_files (filename, authorizer_no, enterer_no, notes, created, modified)
		VALUES ($quoted_name, $authorizer_no, $enterer_no, $quoted_notes, now(), now())";
	
	$result = $dbh->do(encode_utf8($SQL_STRING));
	
	if ( $result )
	{
	    $nexusfile_no = $dbh->last_insert_id(undef, undef, undef, undef);
	    return $nexusfile_no;
	}
	
	else
	{
	    $ERROR_STRING = "Insert error A in NexusEdit.pm: filename=$quoted_name, authorizer_no=$authorizer_no";
	    return 0;
	}
    }
}


=head3 setFileData ( dbt, nexusfile_no, data )

Store the specified data as the contents of the specified nexus file.  The
data must be a text string, and can be as long as necessary.

Line breaks will be normalized to \n.

Returns true on success, false on failure.

=cut

sub setFileData {
    
    my ($dbt, $nexusfile_no, $data) = @_;
    
    my $dbh = $dbt->{dbh};
    
    $nexusfile_no =~ tr/0-9//dc;
    return unless $nexusfile_no > 0;
    
    # Normalize the line breaks.
    
    $data =~ s/\r\n?/\n/g;
    
    # Abort unless we actually have some data.  These files are not supposed
    # to be empty, so leave the old data there.
    
    return unless $data;
    
    # Compute an MD5 digest of the data, so that we can check for duplicate content.
    
    $data = encode_utf8($data);
    
    my $digester = Digest::MD5->new()->add($data);
    my $md5_digest = $dbh->quote($digester->hexdigest());
    
    # Store the data.  Overwrite any existing content.
    
    my $result = $dbh->do("REPLACE INTO nexus_data (nexusfile_no, md5_digest, data) VALUES (?, ?, ?)", {},
			  $nexusfile_no, $md5_digest, $data);
    
    # Update the main record.
    
    $result = $dbh->do("UPDATE nexus_files SET modified=now()
			WHERE nexusfile_no=$nexusfile_no");
    
    return 1;
}


=head3 deleteFile ( dbt, nexusfile_no )

Delete the specified nexus file, plus all of its associated information.

=cut

sub deleteFile {
    
    my ($dbt, $nexusfile_no) = @_;
    
    my $dbh = $dbt->{dbh};
    
    # First make sure we have a valid nexusfile_no.
    
    $nexusfile_no =~ tr/0-9//dc;
    return unless $nexusfile_no > 0;
    
    # Then remove the database rows.
    
    my $result;
    
    $result = $dbh->do("DELETE FROM nexus_files WHERE nexusfile_no=$nexusfile_no");
    $result = $dbh->do("DELETE FROM nexus_refs WHERE nexusfile_no=$nexusfile_no");
    $result = $dbh->do("DELETE FROM nexus_taxa WHERE nexusfile_no=$nexusfile_no");
    $result = $dbh->do("DELETE FROM nexus_data WHERE nexusfile_no=$nexusfile_no");
    
    my $a = 1;		# we can stop here when debugging.
}


=head3 checkWritePermission ( dbt, nexusfile_no, authorizer_no )

Return true if the specified authorizer has permission to write the specified
nexus file.  This is generally true only if the authorizers are the same.

=cut

sub checkWritePermission {
    
    my ($dbt, $nexusfile_no, $authorizer_no) = @_;
    
    my $dbh = $dbt->{dbh};
    
    # First make sure we have a valid nexusfile_no.
    
    $nexusfile_no =~ tr/0-9//dc;
    return unless $nexusfile_no > 0;
    
    # Then fetch the authorizer_no and compare.
    
    my ($file_auth) = $dbh->selectrow_array("
		SELECT authorizer_no FROM nexus_files WHERE nexusfile_no=$nexusfile_no");
    
    return 1 if $file_auth == $authorizer_no and $authorizer_no > 0;
    return; # false, otherwise
}


=head3 setFileInfo ( dbt, nexusfile_no, options )

Update the specified nexus file record with the new information.  The
'modified' time will be updated to the present time.  Returns true if the
update completed properly, or if no update was done.  False if an error
occurred.

Options include:

=over 4

=item notes

Update the 'notes' field of the nexus file record to the specified value.

=item filename

Update the 'filename' field of the nexus file record to the specified value.

=item now

Update the modified-time of the nexus file record (this can be used without
any other options to just set the modified time to the present time).

=back

=cut

sub setFileInfo {

    my ($dbt, $nexusfile_no, $options) = @_;
    
    my $dbh = $dbt->{dbh};
    
    $nexusfile_no =~ tr/0-9//dc;
    return unless $nexusfile_no > 0;
    
    $options ||= {};
    
    # If the options 'notes' was specified, update the notes.
    
    if ( $options->{notes} or $options->{filename} )
    {
	my @updates;
	push @updates, "notes=" . $dbh->quote($options->{notes}) if defined $options->{notes};
	push @updates, "filename=" . $dbh->quote($options->{filename}) if defined $options->{filename} and
	    $options->{filename} ne '';
	push @updates, "modified=now()";
	
	my $update_string = join(', ', @updates);
	
	$SQL_STRING = "UPDATE nexus_files SET $update_string
		       WHERE nexusfile_no=$nexusfile_no";
	
	my $result = $dbh->do(encode_utf8($SQL_STRING));
	
	return $result;
    }
    
    # If the option 'now' was specified, just update the modification time.
    
    elsif ( $options->{now} )
    {
	$SQL_STRING = "UPDATE nexus_files SET modified=now()
		       WHERE nexusfile_no=$nexusfile_no";
	
	my $result = $dbh->do($SQL_STRING);
	
	return $result;
    }
    
    return 1;
}


=head3 addReference ( dbt, nexusfile_no, reference_no )

Associate the specified reference with the specified file.

=cut

sub addReference {
    
    my ($dbt, $nexusfile_no, $reference_no) = @_;
    
    my $dbh = $dbt->{dbh};
    
    $nexusfile_no =~ tr/0-9//dc;
    $reference_no =~ tr/0-9//dc;
    
    return unless $nexusfile_no > 0 and $reference_no > 0;
    
    my ($lastindex) = $dbh->selectrow_array("SELECT max(index_no) FROM nexus_refs
					     WHERE nexusfile_no=$nexusfile_no");
    
    my $index_no = $lastindex + 1;
    
    my $result = $dbh->do("INSERT IGNORE INTO nexus_refs (nexusfile_no, reference_no, index_no)
			   VALUES ($nexusfile_no, $reference_no, $index_no)");
    
    $result = $dbh->do("UPDATE nexus_files SET modified=now()
			WHERE nexusfile_no=$nexusfile_no");
    
    return 1;
}


=head3 deleteReference ( dbt, nexusfile_no, reference_no )

Un-associate the specified reference with the specified file.

=cut

sub deleteReference {

    my ($dbt, $nexusfile_no, $reference_no) = @_;
    
    my $dbh = $dbt->{dbh};
    
    $nexusfile_no =~ tr/0-9//dc;
    $reference_no =~ tr/0-9//dc;
    
    return unless $nexusfile_no > 0 and $reference_no > 0;
    
    my ($del_index) = $dbh->selectrow_array("
		SELECT index_no FROM nexus_refs
		WHERE nexusfile_no=$nexusfile_no and reference_no=$reference_no");
    
    my $result = $dbh->do("
		DELETE FROM nexus_refs
		WHERE nexusfile_no=$nexusfile_no and reference_no=$reference_no");
    
    if ( $del_index > 0 )
    {
	$result = $dbh->do("
		UPDATE nexus_refs SET index_no=index_no-1
		WHERE nexusfile_no=$nexusfile_no and index_no>$del_index");
    }
    
    $result = $dbh->do("UPDATE nexus_files SET modified=now()
			WHERE nexusfile_no=$nexusfile_no");
    
    return 1;
}


=head3 moveReference ( dbt, nexusfile_no, reference_no )

Reorder the references for the specified nexus file so that the specified
reference is the first one (i.e. the primary reference).  By executing a
sequence of such actions, any desired order may be obtained.

=cut

sub moveReference {

    my ($dbt, $nexusfile_no, $reference_no) = @_;
    
    my $dbh = $dbt->{dbh};
    
    $nexusfile_no =~ tr/0-9//dc;
    $reference_no =~ tr/0-9//dc;
    
    return unless $nexusfile_no > 0 and $reference_no > 0;
    
    my ($del_index) = $dbh->selectrow_array("
		SELECT index_no FROM nexus_refs
		WHERE nexusfile_no=$nexusfile_no and reference_no=$reference_no");
    
    my $result;
    
    if ( $del_index > 0 )
    {
	$result = $dbh->do("
		UPDATE nexus_refs SET index_no=index_no+1
		WHERE nexusfile_no=$nexusfile_no and index_no<$del_index");
    }
    
    else
    {
	$result = $dbh->do("
		UPDATE nexus_refs SET index_no=index_no+1
		WHERE nexusfile_no=$nexusfile_no");
    }
    
    $result = $dbh->do("
		UPDATE nexus_refs SET index_no=1
		WHERE nexusfile_no=$nexusfile_no and reference_no=$reference_no");
    
    $result = $dbh->do("UPDATE nexus_files SET modified=now()
			   WHERE nexusfile_no=$nexusfile_no");
    
    return 1;
}


=head3 generateTaxa ( dbt, nexusfile_no, content )

Given the content of a nexus file, generate a list of associated taxa.
Delete the old associated taxa and insert the new list the order they are
specified in the file.

=cut

sub generateTaxa {

    my ($dbt, $nexusfile_no, $content) = @_;
    
    my $dbh = $dbt->{dbh};
    
    # First make sure that we have a valid nexusfile_no.
    
    $nexusfile_no =~ tr/0-9//dc;
    return unless $nexusfile_no > 0;
    
    # First delete all existing associated taxa for this file.
    
    $SQL_STRING = "DELETE FROM nexus_taxa WHERE nexusfile_no = $nexusfile_no";
    
    my $result = $dbh->do($SQL_STRING);
    
    # Then parse the content to get a list of included taxa.
    
    my @file_taxa;
    my $matrix_block;
    
    foreach my $line (split /\r?\n|\r/, $content)
    {
	# Look for the start of the MATRIX section.
	
	if ( !defined $matrix_block and $line =~ /^\s*MATRIX/i )
	{
	    $matrix_block = 'in';
	}
	
	# Parse a line from the MATRIX section
	
	elsif ( $matrix_block eq 'in' )
	{
	    # Look for the end of the MATRIX section
	    
	    if ( $line =~ /^\s*END;/i )
	    {
		$matrix_block = 'done';
		last;	# take this out if we need ever need to look for other stuff
			# after the end of the matrix block
	    }
	    
	    # Every line in this section which starts with optional whitespace
	    # and then a word or phrase (possibly quoted, possibly containing
	    # the characters .?"') is assumed to specify a taxon.  All '_' are
	    # translated to spaces.
	    
	    elsif ( $line =~ /^\s*([^'\s]\S+)/ or $line =~ /^\s*'([^']+)'/ )
	    {
		my $taxon_name = $1;
		$taxon_name =~ s/_+/ /g;
		
		push @file_taxa, $taxon_name;
	    }
	}
    }
    
    my $index_no = 1;
    my ($search_name, @values, @taxa, %found_match);
    my $debug = '';
    
    # Now we go through each of the names and try to match it up to a taxon in
    # the database.
    
    foreach my $name (@file_taxa)
    {
	# Ignore any word ending in a period (i.e. 'spp.'), and any word
	# that starts with a non-word character except '('.  Then remove
	# all characters except letters and ().
	
	my @words = split(/\s+/, $name);
	
	my (@components, $taxon);
	
	foreach my $w (@words)
	{
	    if ( $w =~ /^[\w\(].*[^\.]$/ )
	    {
		$w =~ tr/a-zA-Z()//dc;
		push @components, $w;
	    }
	}
	
	# Now try to match all of the components together.  If no match is
	# found, drop the last one and try again.  Cache successful matches.
	
	my $inexact = 'false';
	
	while (@components)
	{
	    $search_name = join(' ', @components);
	    $debug .= "Search: $search_name\n";
	    
	    # If we've already found this name, we can stop here.
	    
	    if ( $found_match{$search_name} )
	    {
		$taxon = $found_match{$search_name};
		$debug .= "CACHED\n";
		last;
	    }
	    
	    # If the word is "Outgroup", we can ignore it.
	    
	    elsif ( $search_name =~ /^outgroup$/i )
	    {
		$taxon = undef;
		$debug .= "OUTGROUP\n";
		last;
	    }
	    
	    # Otherwise, look for it in the database.
	    
	    ($taxon) = PBDB::TaxonInfo::getTaxa($dbt, { taxon_name => $search_name,
						  match_subgenera => 1 });
	    
	    # If we find it, we can stop here.
	    
	    if ( $taxon )
	    {
		$debug .= ($inexact eq 'true' ? "MATCH INEXACT $taxon->{taxon_name}\n" : "MATCH EXACT $taxon->{taxon_name}\n");
		$found_match{$search_name} = $taxon;
		last;
	    }
	    
	    # Otherwise, we know we have at most an inexact match.  Drop the
	    # last component and try again.
	    
	    $inexact = 'true';
	    pop @components;
	}
	
	$debug .= "FAIL\n" unless ref $taxon;
	
	my $qname = $dbh->quote($name);
	my $qmatch = $dbh->quote($search_name);
	my $taxon_no = $taxon->{taxon_no} || "0";
	
	push @values, "($nexusfile_no, $qname, $qmatch, $taxon_no, $index_no, $inexact)";
	push @taxa, $taxon_no;
	$index_no++;
    }
    
    if ( @values )
    {
	$SQL_STRING = "
		INSERT IGNORE INTO nexus_taxa (nexusfile_no, taxon_name, match_name, orig_no, index_no, inexact)
		VALUES " . join(',', @values);
	
	$result = $dbh->do($SQL_STRING);
	
	my $containing_taxon = PBDB::TaxonInfo::getContainerTaxon($dbt, \@taxa);
	
	if ( $containing_taxon > 0 )
	{
	    $SQL_STRING = "UPDATE nexus_files SET taxon_no=$containing_taxon
		           WHERE nexusfile_no=$nexusfile_no";
	    
	    $result = $dbh->do($SQL_STRING);
	    
	    my $a = 1;		# we can stop here when debugging
	}
    }
    
    #die $debug;
    
    return 1;
}


=head3 updateTaxa ( dbt, nexusfile_no )

For the specified nexus file, find all of its associated taxa where the
match was inexact and try again to match them against the list of known taxa.

=cut

sub updateTaxa {

    my ($dbt, $nexusfile_no) = @_;
    
    my $dbh = $dbt->{dbh};
    
    # First make sure that we have a valid nexusfile_no
    
    $nexusfile_no =~ tr/0-9//dc;
    return unless $nexusfile_no > 0;
    
    # Then look for taxa that are either inexactly matched (t.inexact) or not
    # matched at all (t.orig_no=0).
    
    $SQL_STRING = "
		SELECT t.orig_no as taxon_no, t.taxon_name, t.index_no
		FROM nexus_taxa as t
		WHERE t.nexusfile_no=$nexusfile_no and (t.inexact or t.orig_no=0)";
    
    my ($taxa_list) = $dbh->selectall_arrayref($SQL_STRING, { Slice => {} });
    
    # If there aren't any, we're done.
    
    return unless ref $taxa_list eq 'ARRAY';
    
    # Otherwise, go through each one and try to match it up.  We do this on
    # the off chance that a matching taxon has been added to the database
    # since the last time we went through this procedure.
    
    my (%found_genus);
    
    foreach my $old_t (@$taxa_list)
    {
	my $name = $old_t->{taxon_name};
	my $inexact = 'false';
	my $genus;
	
	if ( $name =~ /^(\w+)\s+\w+/ )
	{
	    $genus = $1;
	}
	
	my ($t) = PBDB::TaxonInfo::getTaxa($dbt, { taxon_name => $name });
	
	unless ( $t )
	{
	    $inexact = 'true';
	    
	    if ( $genus and $found_genus{$genus} )
	    {
		$t = $found_genus{$genus};
	    }
	    
	    elsif ( $genus )
	    {
		($t) = PBDB::TaxonInfo::getTaxa($dbt, { taxon_name => $1 });
		
		unless ( $t )
		{
		    ($t) = PBDB::TaxonInfo::getTaxa($dbt, { taxon_name => $1, match_subgenera => 1 });
		}
		
		elsif ( $2 =~ /\.$/ )
		{
		    $inexact = 'false';
		}
		
		$found_genus{$genus} = $t if $t;
	    }
	    
	    else
	    {
		($t) = PBDB::TaxonInfo::getTaxa($dbt, { taxon_name => $name, match_subgenera => 1 });
	    }
	}
	
	next unless $t;
	next if $t->{taxon_no} == $old_t->{taxon_no};
	
	# If we get here, then we have found a better match than we had before.
	
	my $quoted = $dbh->quote($name);
	
	$SQL_STRING = "UPDATE nexus_taxa SET orig_no=$t->{taxon_no}, inexact=$inexact
		       WHERE nexusfile_no=$nexusfile_no and taxon_name=$quoted";
	
	my $result = $dbh->do($SQL_STRING);
	
	my $a = 1;	# we can stop here when debugging
    }
    
    return 1;
}


1;
