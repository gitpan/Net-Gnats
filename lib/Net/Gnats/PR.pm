package Net::Gnats::PR;
use 5.010_000;
use utf8;
use strict;
use warnings;
use Carp;
use MIME::Base64;

$| = 1;
require Exporter;
use AutoLoader qw(AUTOLOAD);

our @ISA = qw(Exporter);
our $VERSION = '0.11';

# Items to export into callers namespace by default. Note: do not
# export names by default without a very good reason. Use EXPORT_OK
# instead.

# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Net::Gnats ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw( ) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw( );


# TODO: These came from gnatsweb.pl for the parsepr and unparsepr routines.
# should be done a better way?
my $UNFORMATTED_FIELD = 'Unformatted';
my $SYNOPSIS_FIELD = 'Synopsis';
my $ORIGINATOR_FIELD = 'Originator';
my $attachment_delimiter = "----gnatsweb-attachment----\n";
my $SENDINCLUDE  = 1;   # whether the send command should include the field
our $REVISION = '$Id: PR.pm,v 1.7 2014/08/15 15:34:25 thacker Exp $'; #'

#******************************************************************************
# Sub: new
# Description: Constructor
# Args: hash (parameter list) 
# Returns: self
#******************************************************************************
sub new {
    my ( $class, $gnatsobj ) = @_;
    my $self = bless {}, $class;

    $self->{__gnatsObj} = $gnatsobj;
    $self->{number} = undef;
    $self->{fields} = undef;
    confess '? Error: Must pass Net::Gnats object as first argument'
      if (not defined $self->{__gnatsObj});
    return $self;
}

sub setField {
    my ($self, $field, $value, $reason) = @_;
    $self->{fields}->{$field} = $value;
    $self->{fields}->{$field."-Changed-Why"} = $reason
      if (defined($reason)); # TODO: Anyway to find out if requireChangeReason?
}

sub getField {
    my ( $self, $field ) = @_;
    return $self->{fields}->{$field};
}

# This is legacy...
sub getNumber {
  return $_[0]->getField("Number");
}

sub getKeys {
    my $self = shift;
    return keys(%{$self->{fields}});
}

sub asHash {
    my ( $self ) = shift;
    return %{$self->{fields}} if defined($self->{fields}); #XXX Deep copy?
    return undef;
}

# This return remains, sine it was in the examples.
sub asString {
  my $self = shift;
  return $self->unparse(@_);
}

# Split comma-separated list.
# Commas in quotes are not separators!
sub split_csl {
  my ($list) = @_;

  # Substitute commas in quotes with \002.
  while ($list =~ m~"([^"]*)"~g)
  {
    my $pos = pos($list);
    my $str = $1;
    $str =~ s~,~\002~g;
    $list =~ s~"[^"]*"~"$str"~;
		 pos($list) = $pos;
  }

  my @res;
  foreach my $person (split(/\s*,\s*/, $list))
  {
    $person =~ s/\002/,/g;
    push(@res, $person) if $person;
  }
  return @res;
}

# fix_email_addrs -
#     Trim email addresses as they appear in an email From or Reply-To
#     header into a comma separated list of just the addresses.
#
#     Delete everything inside ()'s and outside <>'s, inclusive.
#
sub fix_email_addrs
{
  my $addrs = shift;
  my @addrs = split_csl ($addrs);
  my @trimmed_addrs;
  my $addr;
  foreach $addr (@addrs)
  {
    $addr =~ s/\(.*\)//;
    $addr =~ s/.*<(.*)>.*/$1/;
    $addr =~ s/^\s+//;
    $addr =~ s/\s+$//;
    push(@trimmed_addrs, $addr);
  }
  $addrs = join(', ', @trimmed_addrs);
  $addrs;
}

sub parse_line {
  my ( $self, $line, $known_fields) = @_;
  my $result = [];
  my @found = $line =~ /^>([\w\-]+):\s*(.*)$/;

  if ( not defined $found[0] ) {
    @{ $result }[1] = $line;
    return $result;
  }

  my $found = grep { $_ eq $found[0] } @{ $known_fields };

  if ( $found == 0 ) {
    @{ $result }[1] = $line;
    return $result;
  }

  @{ $result }[0] =  $found[0];
  $found[1] =~ s/\s+$//;
  @{ $result }[1] = $found[1];
  return $result;
}

sub parse {
  my $self  = shift;

  # Get all known fields and hashify them.
  my $fields_known = $self->{__gnatsObj}->list_fieldnames;
  my $fields_have = {};

  my ( $field_last );
  my $field_multi = 0;

  foreach (@_) {
    my $result = $self->parse_line( $_, $fields_known );

    # known header field found, save.
    if ( defined @{ $result }[0] ) {
      $fields_have->{ @{ $result }[0] } = @{ $result }[1];

      # if the last field was a multi, remove its auto newline
      if ( $field_multi ) {
        $fields_have->{ $field_last } =~ s/\n$//;
      }
      $field_multi = 0;
      $field_last = @{ $result }[0];
    }
    # known header field not found, append to last.
    else {
      if ( not defined $field_last ) { next; }
      $field_multi = 1;
      $fields_have->{ $field_last } .= @{ $result }[1] . "\n";
    }
  }

  $fields_have->{'Reply-To'} = $fields_have->{'Reply-To'} || $fields_have->{'From'};
  delete $fields_have->{'From'};

  $fields_have->{'X-GNATS-Notify'} ||= '';

  # 3/30/99 kenstir: For some reason Unformatted always ends up with an
  # extra newline here.
  $fields_have->{$UNFORMATTED_FIELD} ||= ''; # Default to empty value
  $fields_have->{$UNFORMATTED_FIELD} =~ s/\n$//;

  # Decode attachments stored in Unformatted field.
  my $any_attachments = 0;

  my(@attachments) = split /$attachment_delimiter/, $fields_have->{$UNFORMATTED_FIELD};

  # First element is any random text which precedes delimited attachments.
  $fields_have->{$UNFORMATTED_FIELD} = shift @attachments;
  foreach my $attachment (@attachments) {
      $any_attachments = 1;
      $attachment =~ s/^[ ]//mg;
      add_decoded_attachment_to_pr($fields_have, decode_attachment($attachment));
    }

  foreach my $field (keys %{ $fields_have }) {
    $fields_have->{$field} =~ s/\r// if defined $fields_have->{ $field };
    $self->setField($field, $fields_have->{$field})
  }
}

# unparse -
#     Turn PR fields hash into a multi-line string.
#
#     The $purpose arg controls how things are done.  The possible values
#     are:
#         'gnatsd'  - PR will be filed using gnatsd; proper '.' escaping done
#         'send'    - PR will be field using gnatsd, and is an initial PR.
#         'test'    - we're being called from the regression tests
sub unparse {
  my ( $self, $purpose ) = @_;
  $purpose ||= 'gnatsd';
  my ( $tmp, $text );
  my $debug = 0;

  # First create or reconstruct the Unformatted field containing the
  # attachments, if any.
  my %fields = %{$self->{fields}};
  $fields{$UNFORMATTED_FIELD} ||= ''; # Default to empty.
  warn "unparsepr 1 =>$fields{$UNFORMATTED_FIELD}<=\n" if $debug;
  my $array_ref = $fields{'attachments'};
  foreach my $hash_ref (@$array_ref) {
    my $attachment_data = $$hash_ref{'original_attachment'};
    # Deleted attachments leave empty hashes behind.
    next unless defined($attachment_data);
    $fields{$UNFORMATTED_FIELD} .= $attachment_delimiter . $attachment_data . "\n";
  }
  warn "unparsepr 2 =>$fields{$UNFORMATTED_FIELD}<=\n" if $debug;

  # Reconstruct the text of the PR into $text.
  # Build the envelope if necessary.
  if (exists $fields{'envelope'}) {
    $text = $fields{'envelope'};
  } else {
    $text = "To: bugs
CC:
Subject: $fields{$SYNOPSIS_FIELD}
From: $fields{$ORIGINATOR_FIELD}
Reply-To: $fields{$ORIGINATOR_FIELD}
X-Send-Pr-Version: Net::Gnats-$Net::Gnats::VERSION ($REVISION)

";
  }

  foreach (@{ $self->{__gnatsObj}->list_fieldnames } ) {
    next if /^.$/;
    next if (not defined($fields{$_})); # Don't send fields that aren't defined.
    # Do include Unformatted field in 'send' operation, even though
    # it's excluded.  We need it to hold the file attachment.
    # XXX ??? !!! FIXME
    if(($purpose eq 'send')
       && (! ($self->{__gnatsObj}->getFieldTypeInfo ($_, 'flags') & $SENDINCLUDE))
       && ($_ ne $UNFORMATTED_FIELD))
    {
      next;
    }
    $fields{$_} ||= ''; # Default to empty
    if($self->{__gnatsObj}->getFieldType($_) eq 'MultiText')
    {
      # Lines which begin with a '.' need to be escaped by another '.'
      # if we're feeding it to gnatsd.
      $tmp = $fields{$_};
      $tmp =~ s/\r//;
      $tmp =~ s/^[.]/../gm
            if ($purpose ne 'test');
      chomp($tmp);
      $tmp .= "\n" if ($tmp ne ""); # Make sure it ends with newline.
      $text .= sprintf(">$_:\n%s", $tmp);
    }
    else
    {
      # Format string derived from gnats/pr.c.
      $text .= sprintf("%-16s %s\n", ">$_:", $fields{$_});
    }
    if (exists ($fields{$_."-Changed-Why"}))
    {
      # Lines which begin with a '.' need to be escaped by another '.'
      # if we're feeding it to gnatsd.
      $tmp = $fields{$_."-Changed-Why"};
      $tmp =~ s/^[.]/../gm
            if ($purpose ne 'test');
      $text .= sprintf(">$_-Changed-Why:\n%s\n", $tmp);
    }
  }
  $text =~ s/\r//;
  return $text;
}


# preloaded methods go here.

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__

=head1 NAME

Net::Gnats::PR - Represents a Gnats PR.

=head1 SYNOPSIS

  use Net::Gnats;
  my $g = Net::Gnats->new();
  $g->connect();
  my @dbNames = $g->getDBNames();
  $g->login("default","somedeveloper","password");
  my $PRtwo = $g->getPRByNumber(2);
  print $PRtwo->asString();
  my $newPR = Net::Gnats::PR->new();
  $newPR->setField("Submitter-Id","developer");
  $g->submitPR($newPR);
  $g->disconnect();


=head1 DESCRIPTION

Net::Gnats::PR models a GNU Gnats PR (Problem Report).  The module allows
proper formatting and parsing of PRs through an object oriented interface.

The current version of Net::Gnats (as well as related information) is 
available at http://gnatsperl.sourceforge.net/

=head1 COMMON TASKS


=head2 CREATING A NEW PR

The Net::Gnats::PR object acts as a container object to store information
about a PR (new or otherwise).  A new PR is submitted to gnatsperl by 
constructing a PR object.

  my $newPR = Net::Gnats::PR->new();
  $newPR->setField("Submitter-Id","developer");
  $newPR->setField("Originator","Doctor Wifflechumps");
  $newPR->setField("Organization","GNU");
  $newPR->setField("Synopsis","Some bug from perlgnats");
  $newPR->setField("Confidential","no");
  $newPR->setField("Severity","serious");
  $newPR->setField("Priority","low");
  $newPR->setField("Category","gnatsperl");
  $newPR->setField("Class","sw-bug");
  $newPR->setField("Description","Something terrible happened");
  $newPR->setField("How-To-Repeat","Like this.  Like this.");
  $newPR->setField("Fix","Who knows");

Obviously, fields are dependent on a specific gnats installation,
since Gnats administrators can rename fields and add constraints.


=head2 CREATING A NEW PR OBJECT FROM A PREFORMATTED PR STRING 

Instead of setting each field of the PR individually, the
setFromString() method is available.  The string that is passed to it
must be formatted in the way Gnats handles the PRs (i.e. the '>Field:
Value' format.  You can see this more clearly by looking at the PR
files of your Gnats installation).  This is useful when handling a
Gnats email submission ($newPR->setFromString($email)) or when reading
a PR file directly from the database.


=head1 METHOD DESCRIPTIONS


=head2 new()

Constructor, no arguments.

=head2 setField()

Sets a gnats field value.  Expects two arguments: the field name followed by
the field value.

=head2 getField()

Returns the string value of a PR field.

=head2 getNumber()

Returns the gnats PR number. In previous versions of gnatsperl the Number field was
explicitly known to Net::Gnats::PR.  This method remains for backwards compatibility.

=head2 asHash()

Returns the PR formatted as a hash.  The returned hash contains field names
as keys, and the corresponding field values as hash values.

=head2 getKeys()

Returns the list of PR fields contained in the object.  


=head2 asString()

Returns the PR object formatted as a Gnats recongizable string.  The result
is suitable for submitting to Gnats.

=head2 setFromString()

Parses a Gnats formatted PR and sets the object's fields accordingly.





=head1 BUGS

Bug reports are very welcome.  Please submit to the project page 
(noted below).


=head1 AUTHOR

Mike Hoolehan, <lt>mike@sycamore.us<gt>
Project hosted at sourceforge, at http://gnatsperl.sourceforge.net



=head1 COPYRIGHT

Copyright (c) 1997-2001, Mike Hoolehan. All Rights Reserved.
This module is free software. It may be used, redistributed,
and/or modified under the same terms as Perl itself.


=cut

