package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = 2.99_13;  # $Date: 1999/11/19 11:04:10 $

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
 $p = HTML::Parser->new;  # should really a be subclass
 $p->parse($chunk1);
 $p->parse($chunk2);
 #...
 $p->eof;                 # signal end of document

 # Parse directly from file
 $p->parse_file("foo.html");
 # or
 open(F, "foo.html") || die;
 $p->parse_file(*F);

=head1 DESCRIPTION

B<Note: > This is the new experimental XS based HTML::Parser.  It
should be completely backwards compatible with HTML::Parser version
2.2x, but has many new features (not documented yet).  The rest of
this manual page describes HTML::Parser v2.25.

The C<HTML::Parser> will tokenize an HTML document when the parse() or
parse_file() methods are called.  Tokens are reported by invoking
various callback methods.  The document to be parsed can be supplied
in arbitrary chunks.

=head2 External interface Methods

=item $p = HTML::Parser->new( 'handlers' => { event => \&subroutine, ... } )

The object constructor creates a HTML::Parser object
and may assign callback subroutines for various events.

=item $p->parse( $string );

Parse $string as the next chunk of the HTML document.  The return
value is a reference to the parser object (i.e. $p).

=item $p->eof

Signals the end of the HTML document.  Calling the eof() method will
flush any remaining buffered text.  The return value is a reference to
the parser object.

=item $p->parse_file( $file );

This method can be called to parse text directly from a file.  The
$file argument can be a filename or an already opened file handle (or
a reference to such a handle).

If $file is a plain filename and the file can't be opened, then the
method will return an undefined value and $! will tell you why it
failed.  In all other cases the return value will be a reference to
the parser object.

If a filehandle is passed in, then the file will be read until EOF,
but not otherwise affected.

=head2 Callback Subroutines

Callback subroutines may be assigned to events as arguments to
the constructor or by calling $p->callback.
Assigned callbacks override the corresponding subclass methods.

If $p->pass_self is enabled, $p will be passed ahead of the other arguments.

=item $p->callback( event => \&subroutine )

This method assigns a subroutine (which may be an anonymous subroutine)
as a callback for an event.

=over 4

=item text_cb => \&text( $text )

This event is triggered when plain text in the document is recognized.
The text is passed unmodified and might contain multiple lines.
Note that for efficiency reasons entities in the text are B<not>
expanded unless $p->decode_text_entities is enabled.
If it isn't, you should call HTML::Entities::decode($text) before you
process the text any further.

A sequence of text in the HTML document may be broken between several
invocations of $self->text unless $p->unbroken_text is enabled.

The parser will make sure that it does not break a word or
a sequence of spaces between two events.


=item start_cb => \&start( $tag, $attr, $attrseq, $origtext )

This event is triggered when a complete start tag has been recognized.
The first argument is the tag name (in lower case) and the second
argument is a reference to a hash that contain all attributes found
within the start tag.  The attribute keys are converted to lower case.
Entities found in the attribute values are already expanded.  The
third argument is a reference to an array with the lower case
attribute keys in the original order.  The fourth argument is the
original HTML text.



=item end_cb => \&end( $tag, $origtext )

This event is triggered when an end tag has been recognized.
The first argument is the lower case tag name, the second the original
HTML text of the tag.


=item decl_cb => \&declaration( $string )

This event is triggered when a I<markup declaration> has been recognized.
The only argument is the declaration text.
Comments and the surrounding "<!" and ">" are removed.
Entities are B<not> be expanded.

For typical HTML documents, the only declaration you are
likely to find is <!DOCTYPE ...>.


=item com_cb => \&comment( $comment )

This event is triggered when a comment is recognized.
The leading and trailing "--" sequences have been stripped
from the comment text.


=item pi_cb



=item default_cb


=back

=head2 Boolean Attribute Accessor Methods

Each attribue is enabled by calling the corresponding method
with a TRUE argument and disabled with a FALSE argument.

The return value from each method is the old attribute value.

=item $p->strict_comment( [$bool] )

By default, comments are terminated by the first occurrence of "-->".
This is close to the behaviour of some popular browsers
(like Netscape and MSIE),
but it is not correct according to the "official" HTML standards.

The official behaviour is enabled by enabling this attribute.

=item $p->strict_names( [$bool] )

By default, almost anything is allowed in tag and attribute names.
This is close to the behaviour of some popular browsers and allows us
to parse some broken tags with invalid values in the attr values like:
   <IMG ALIGN=MIDDLE SRC=newprevlstGr.gif ALT=[PREV LIST] BORDER=0> 

The official behaviour is enabled by enabling this attribute.

=item $p->decode_text_entities( [$bool] )

When this attribute is enabled, HTML entities passed to $self->text()
or the text callback (&amp;, &#256;, ...) are automatically decoded.

=item $p->keep_case( [$bool] )

By default, tag and attr names are forced to lower case.
When this attribute is enabled, the original text of the names is preserved.

Enabling xml_mode also causes this behaviour without changing this attribute.

=item $p->xml_mode( [$bool] )

Enabling this attribute changes the parser to allow XML tags.
It also disables forcing tag and attr names to lower case,
changes the way that empty tags are handled,
and allows '/' as the last character inside a start tag.

An empty XML tag causes an artificial end tag to be generated.

=item $p->v2_compat( [$bool] )

Enabling this attribute causes start parameter reporting to be
closer to the behaviour of HTML::Parser v2.

XXX What is the difference?

=item $p->pass_self( [$bool] )

Enabling this attribute causes $self to be the first argument
to callback subroutines so they can act like method calls.

XXX Should this be implied by v2_compat?

=item $p->unbroken_text( [$bool] )

By default, blocks of text may be returned in one or more pieces
which may be of any length, but won't end inside a word.
When this attribute is enabled
blocks of text are always returned in one piece.

Text in cdata sections may still be broken up.

=item $p->attr_pos( [$bool] )

By default, attrs in a start tag are reported by passing
a reference to an array of attr names and a reference to
a hash of array names and values.
When this attribute is enabled a reference to an array
is substituted for the attr value.

The array elements are the offsets in the tag text of
(1) the end of the previous attr value or name,
(2) the start of the attr name,
(3) the start of the attr value (undef if no value), and
(4) the end of the attr value (name if no value).

In this case, the attr value will not have HTML entities decoded.

=item $p->marked_section( [$bool] )

B<Note:> This attribute is only available
if the Marked Section option was selected at compile time.

By default section markings like CDATA[] are treated like ordinary text.
When this attribute is enabled section markings are honored.

XXX I don't really know what this is about.

=head2 Subclassing

The default implementation of these methods do nothing, i.e., the
tokens are just ignored.
This was the only way to modify the behaviour of HTML::Parser v2.

In order to make the parser do anything interesting, you must make a
subclass where you override one or more of the following methods as
appropriate or assign callback subroutines.


=item $self->declaration($decl)

This method is called when a I<markup declaration> has been
recognized.  For typical HTML documents, the only declaration you are
likely to find is <!DOCTYPE ...>.  The initial "<!" and ending ">" is
not part of the string passed as argument.  Comments are removed and
entities will B<not> be expanded.

=item $self->start($tag, $attr, $attrseq, $origtext)

This method is called when a complete start tag has been recognized.
The first argument is the tag name (in lower case) and the second
argument is a reference to a hash that contain all attributes found
within the start tag.  The attribute keys are converted to lower case.
Entities found in the attribute values are already expanded.  The
third argument is a reference to an array with the lower case
attribute keys in the original order.  The fourth argument is the
original HTML text.


=item $self->end($tag, $origtext)

This method is called when an end tag has been recognized.  The
first argument is the lower case tag name, the second the original
HTML text of the tag.

=item $self->text($text)

This method is called when plain text in the document is recognized.
The text is passed on unmodified and might contain multiple lines.
Note that for efficiency reasons entities in the text are B<not>
expanded unless $p->decode_text_entities is enabled.
If it isn't, you should call HTML::Entities::decode($text) before you
process the text any further.

A sequence of text in the HTML document can be broken between several
invocations of $self->text.  The parser will make sure that it does
not break a word or a sequence of spaces between two invocations of
$self->text().

=item $self->comment($comment)

This method is called as comments are recognized.  The leading and
trailing "--" sequences have been stripped off the comment text.

=head2 SGML

There is really nothing in the basic parser that is HTML specific, so
it is likely that the parser can parse other kinds of SGML documents.
SGML has many obscure features (not implemented by this module) that
prevent us from renaming this module as C<SGML::Parser>.

=head1 EFFICIENCY

The parser is fairly inefficient if the chunks passed to $p->parse()
are too big.  The reason is probably that perl ends up with a lot of
character copying as tokens are chopped of from the beginning of the
strings.  A chunk size of about 256-512 bytes was optimal in a test I
made with some real world HTML documents.  (The parser was about 3
times slower with a chunk size of 20K).

=head1 SEE ALSO

L<HTML::Entities>, L<HTML::TokeParser>, L<HTML::Filter>,
L<HTML::HeadParser>, L<HTML::LinkExtor>

L<HTML::TreeBuilder> (part of the I<HTML-Tree> distribution)

=head1 COPYRIGHT

Copyright 1996-1999 Gisle Aas. All rights reserved.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
