package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = 2.99_13;  # $Date: 1999/11/19 13:04:35 $

require HTML::Entities;

require DynaLoader;
@ISA=qw(DynaLoader);
HTML::Parser->bootstrap($VERSION);

sub new
{
    my $class = shift;
    my $self = bless {}, $class;
    _alloc_pstate($self);
    if (@_) {
	my %cfg = @_;

	if (my $h = delete $cfg{handlers}) {
	    $h = {@$h} if ref($h) eq "ARRAY";
	    while (my($event, $cb) = each %$h) {
		$self->callback($event => $cb);
	    }
	}

	# In the end we try to assume plain attribute or callback
	for (keys %cfg) {
	    if (/^(\w+)_cb$/) {
		$self->callback($1 => $cfg{$_});
	    }
	    else {
		$self->$_($cfg{$_});
	    }
	}
    }
    else {
	# Set up method callbacks for compatibility with HTML-Parser-2.xx
	$self->pass_self(1);    # get back $self as first argument
	$self->v2_compat(1);    # fix start parameters

	$self->callback(text        => sub { shift->text(@_)});
	$self->callback(end         => sub { shift->end(@_)});
	$self->callback(comment     => sub { shift->comment(@_)});
	$self->callback(declaration => sub { shift->declaration(@_)});
	$self->callback(process     => sub { shift->process(@_)});
	$self->callback(start       => sub { shift->start(@_)});
    }
    $self;
}


sub eof
{
    shift->parse(undef);
}


sub parse_file
{
    my($self, $file) = @_;
    my $opened;
    if (!ref($file) && ref(\$file) ne "GLOB") {
        # Assume $file is a filename
        local(*F);
        open(F, $file) || return undef;
	binmode(F);  # should we? good for byte counts
        $opened++;
        $file = *F;
    }
    my $chunk = '';
    while(read($file, $chunk, 512)) {
        $self->parse($chunk);
	last if delete $self->{parse_file_stop};
    }
    close($file) if $opened;
    $self->eof;
}


sub netscape_buggy_comment  # legacy
{
    my $self = shift;
    if ($^W) {
	warn "netscape_buggy_comment() is depreciated.  Please use the strict_comment() method instead";
    }
    my $old = !$self->strict_comment;
    $self->strict_comment(!shift) if @_;
    return $old;
}


# set up method stubs
sub text { }
*declaration = \&text;
*process     = \&text;
*comment     = \&text;
*start       = \&text;
*end         = \&text;

1;

__END__


=head1 NAME

HTML::Parser - HTML tokenizer

=head1 SYNOPSIS

 require HTML::Parser;
 $p = HTML::Parser->new( %options );
 $p->parse($chunk1);
 $p->parse($chunk2);
 #...
 $p->eof;                 # signal end of document

 # Parse directly from file
 $p->parse_file("foo.html");
 # or
 open(F, "foo.html") || die;
 $p->parse_file(*F);

=head1 NOTE

This is the new experimental XS based HTML::Parser.  It should be
completely backwards compatible with HTML::Parser version 2.2x, but
has many new features.

=head1 DESCRIPTION

The C<HTML::Parser> will tokenize an HTML document when the parse() or
parse_file() methods are called.  Tokens are reported by invoking
various callback methods or by accumulating tokens in an array.  The
document to be parsed can be supplied in arbitrary chunks.

[XXX Some more general talk...]

=head1 METHODS

=over

=item $p = HTML::Parser->new( %options_and_callbacks )

The object constructor creates a HTML::Parser object
and may assign callback subroutines for various events.

[XXX describe how %options_and_callbacks maps to the callback method
and the various boolean options.]

For compatibility with HTML::Parser version 2 the constructor will set
up method callbacks and turn on the $p->v2_compat option if no
%options_and_callbacks are given.

=item $p->parse( $string )

Parse $string as the next chunk of the HTML document.  The return
value is a reference to the parser object (i.e. $p).

=item $p->eof

Signals the end of the HTML document.  Calling the eof() method will
flush any remaining buffered text.  The return value is a reference to
the parser object.

=item $p->parse_file( $file )

This method can be called to parse text directly from a file.  The
$file argument can be a filename or an already opened file handle (or
a reference to such a handle).

If $file is a plain filename and the file can't be opened, then the
method will return an undefined value and $! will tell you why it
failed.  In all other cases the return value will be a reference to
the parser object.

If a filehandle is passed in, then the file will be read until EOF,
but not otherwise affected.

=item $p->callback( event => \&subroutine )

This method assigns a subroutine (which may be an anonymous
subroutine) as a callback for an event.  Event is one of C<text>,
C<start>, C<end>, C<declaration>, C<comment>, C<process> or
C<default>.  Look at L</HANDLERS> for details on arguments passed to
the callbacks.

=item $p->bool_attr_value( $val )

This method sets up the value reported for boolean attributes inside
HTML start tags.  By default the name of the attribute is also used as
its value.

=item $p->accum( $array_ref )

This method tell the parser to not make callbacks but instead append
entries to the array given as tokens are recognized.

[XXX Describe how tokens are reported (similar to HTML::TokeParser)]

=back


=head1 PARSER OPTIONS

Parser options are represented by boolean parser attributes.  Each
attribute is enabled by calling the corresponding method with a TRUE
argument and disabled with a FALSE argument.  The attribute value is
left unchanged if no argument is given.  The return value from each
method is the old attribute value.

The boolean parser option methods are:

=over

=item $p->strict_comment( [$bool] )

By default, comments are terminated by the first occurrence of "-->".
This is the behaviour of most popular browsers (like Netscape and
MSIE), but it is not correct according to the "official" HTML
standards.

The official behaviour is enabled by enabling this attribute.

=item $p->strict_names( [$bool] )

By default, almost anything is allowed in tag and attribute names.
This is the behaviour of most popular browsers and allows us to parse
some broken tags with invalid values in the attr values like:

   <IMG SRC=newprevlstGr.gif ALT=[PREV LIST] BORDER=0>

The official behaviour is enabled by enabling this attribute.  This
will make a tag like the one above be parsed as text instead.

=item $p->decode_text_entities( [$bool] )

When this attribute is enabled, HTML entities (&amp;, &#255;, ...) are
automatically decoded in the text reported.

=item $p->keep_case( [$bool] )

By default, tag and attr names are forced to lower case.  When this
attribute is enabled, the original text of the names is preserved.

Enabling xml_mode also causes this behaviour even if the keep_case
value remain FALSE.

=item $p->xml_mode( [$bool] )

Enabling this attribute changes the parser to allow some XML tags.  It
also disables forcing tag and attr names to lower case.

Empty element tags are like start tags, but ends with the characters
"/>".  When recognized by HTML::Parser these will causes an artificial
end tag to be generated in addition to the start tag.

Processing instructions are terminated by "?>" instead of simply ">".

=item $p->v2_compat( [$bool] )

Enabling this attribute causes start parameter reporting to be closer
to the behaviour of HTML::Parser v2.  More information in L</VERSION 2
COMPATIBILITY>.

=item $p->pass_self( [$bool] )

Enabling this attribute causes $self to be the first argument to
callback subroutines.  Useful if the callback wants to access
attributes of the parser object or call methods on it.

(If register closures with references to the parser as handlers, then
you effectively create circular sturctures that prevent the parser
from being garbarge collected.)

XXX Should this be implied by v2_compat?

=item $p->unbroken_text( [$bool] )

By default, blocks of text may be returned in one or more pieces
which may be of any length, but won't end inside a word.
When this attribute is enabled
blocks of text are always returned in one piece.

Text in cdata sections may still be broken up.  [XXX Wrong!]

=item $p->attr_pos( [$bool] )

By default, attrs in a start tag are reported by passing
a reference to an array of attr names and a reference to
a hash of array names and values.
When this attribute is enabled a reference to an array
is substituted for the attr value.

The array elements are the offsets in the tag text of

 (0) the end of the previous attr value or name,
 (1) the start of the attr name,
 (2) the start of the attr value (undef if no value), and
 (3) the end of the attr value (name if no value).

Examples of use:

 $pos = $attr->{bgcolor};
 if ($pos) {
    # kill any bgclor attributes
    substr($origtext, $pos->[0], $pos->[3] - $pos->[0]) = "";

    # set value to yellow
    substr($origtext, $pos->[2], pos->[3] - $pos->[2]) = "yellow";

    # update attribute name
    substr($origtext, $pos->[1], length("bgcolor") = "x-bgcolor";
 }


=item $p->marked_section( [$bool] )

B<Note:> This attribute is only available
if the Marked Section option was selected at compile time.

By default section markings like <![CDATA[...]]> are treated like
ordinary text.  When this attribute is enabled section markings are
honored.

XXX I don't really know what this is about.

http://www.sgml.u-net.com/book/sgml-8.htm

=back



=head1 HANDLERS

Callback subroutines may be assigned to events as arguments to
the constructor or by calling $p->callback.
Assigned callbacks override the corresponding subclass methods.

If $p->pass_self is enabled, $p will be passed ahead of the other
arguments.

=over

=item text( $text, $cdata_flag )

This event is triggered when plain text in the document is recognized.
The text might contain multiple lines.  A sequence of text in the HTML
document may be broken between several invocations of the text handler
unless $p->unbroken_text is enabled.

The parser will make sure that it does not break a word or
a sequence of spaces between two events.

The $cdata_flag is TRUE if $text might contain entity references that
should be expanded.  If $p->decode_text_entities is enabled, then the
$cdata_flag will always be TRUE.  If $p->decode_text_entities is
disabled, then this flag will only be true for text found inside CDATA
elements, like <script>, <style>, <xmp> and for CDATA marked sections.

When $cdata_flag is FALSE (or missing) then you might want to call
HTML::Entities::decode($text) before you process the text any further.


=item start( $tag, $attr, $origtext )

This event is triggered when a complete start tag has been recognized.
The first argument is the tag name (in lower case) and the second
argument is a reference to an array that contain all attributes found
within the start tag.  Attributes are prepresented by key/value pairs.
The attribute keys are converted to lower case.  Any entities found in
the attribute values are already expanded.

The third argument is the original HTML text.

=item end( $tag, $origtext )

This event is triggered when an end tag has been recognized.
The first argument is the lower case tag name, the second the original
HTML text of the tag.


=item declaration( $tokens, $origtext )

This event is triggered when a I<markup declaration> has been recognized.

For typical HTML documents, the only declaration you are
likely to find is <!DOCTYPE ...>.


=item comment( $comment )

This event is triggered when a comment is recognized.
The leading and trailing "--" sequences have been stripped
from the comment text.

[XXX: Should there be an $origtext?  One problem is that if you turn
on $p->strict_comment, then a comment like this one <!-- foo -- -- bar
--> will be reported as two comments, and then $origtext does not make
sense.]


=item process( $content, $origtext )

This event is triggered when a process instruction is recognized.

<http://www.sgml.u-net.com/book/sgml-8.htm>

=item default( $origtext )

This event is triggered for anything that does not have a specific
callback.

Example that strips out <font> tags:

  sub ignore_font { print pop unless shift eq "font" }
  HTML::Parser->new(default_cb => sub { print shift },
                    start_cb => \&ignore_font,
                    end_cb => \&ignore_font,
                   )->parse_file(shift)

Example that strips comments:

  HTML::Parser->new(default_cb => sub { print shift },
                    comment_cb => sub { },
                   )->parse_file(shift);

=back

=head1 VERSION 2 COMPATIBILITY

[XXX Describe callback methods in general and how they map to the handlers
described above.]

[XXX Describe how the arguments for the start callback method differ
from what is described for the start handler above.  [Attributes are
reported as a hash and an additional \@attr_seq argument is inserted]

[XXX Describe the effect of $p->v2_compat.]


=head1 EXAMPLES

[XXX I want this to be a HTML::Parser cookbook.  Also show how we
simplify all the HTML recipes found in the "Perl Cookbook" with the
new features.]

=head1 SEE ALSO

L<HTML::Entities>, L<HTML::TokeParser>, L<HTML::Filter>,
L<HTML::HeadParser>, L<HTML::LinkExtor>

L<HTML::TreeBuilder> (part of the I<HTML-Tree> distribution)

=head1 COPYRIGHT

Copyright 1996-1999 Gisle Aas. All rights reserved.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
