package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
# Copyright 1999, Michael A. Chase.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = 2.99_15;  # $Date: 1999/11/30 21:50:43 $

require HTML::Entities;

require DynaLoader;
@ISA=qw(DynaLoader);
HTML::Parser->bootstrap($VERSION);

sub new
{
    my $class = shift;
    my $self = bless {}, $class;
    _alloc_pstate($self);
    if (@_ > 1) {
	my %cfg = @_;

	if (my $h = delete $cfg{handlers}) {
	    $h = {@$h} if ref($h) eq "ARRAY";
	    while (my($event, $cb) = each %$h) {
		$self->handler($event => $cb);
	    }
	}

	# In the end we try to assume plain attribute or callback
	for (keys %cfg) {
	    if (/^(\w+)_h$/) {
		$self->handler($1 => $cfg{$_});
	    }
	    else {
		$self->$_($cfg{$_});
	    }
	}
    }
    elsif (!$_[0] || $_[0] < 3) {
	# Set up method callbacks for compatibility with HTML-Parser-2.xx
	$self->handler(text    => "text",    "self,origtext,cdata_flag");
	$self->handler(end     => "end",     "self,tagname,origtext");
	$self->handler(process => "process", "self,token1,origtext");
	$self->handler(start   => "start",
		                  "self,tagname,attr,attrseq,origtext");

	$self->handler(comment =>
		       sub {
			   my($self, $tokens) = @_;
			   for (@$tokens) {
			       $self->comment($_);
			   }
		       }, "self,tokens");

	$self->handler(declaration =>
		       sub {
			   my $self = shift;
			   $self->declaration(substr($_[0], 2, -1));
		       }, "self,origtext");
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
*start       = \&text;
*end         = \&text;
*comment     = \&text;
*declaration = \&text;
*process     = \&text;

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

This is the new and still experimental XS based HTML::Parser.  It
should be completely backwards compatible with HTML::Parser version
2.2x, but has many new features.  This is currently an alpha release.
The interface to the new features might still change.

B<Warning: This manual page is not up to date.  Lot of the new stuff
has changed recently.>

=head1 DESCRIPTION

The C<HTML::Parser> will tokenize an HTML document when the parse() or
parse_file() methods are called.  Tokens are reported by invoking
various callback methods or by accumulating tokens in an array.  The
document to be parsed can be supplied in arbitrary chunks.

[XXX Some more general talk...]

=head1 METHODS

=over

=item $p = HTML::Parser->new( %options_and_callbacks )

The object constructor creates a new C<HTML::Parser> object and
returns it.  The constructor takes key/value arguments that can set up
event handlers or configure various options.

If the key ends with the suffix "_cb" then it sets up a callback
handler, otherwise it simply assigns some plain attribute.  Example:

   $p = HTML::Parser->new(text_cb => sub { ...},
                          decode_text_entities => 1,
                         );

This will create a new parser object, set up an text handler, and
enable automatic decoding of text entities.  As an alternative you can
assign handlers like this:

  $p = HTML::Parser->new(handlers => { text => sub {...},
                                       comment => sub {...},
                                     },
                         decode_text_entities => 1,
                        );

If the constructor is called without any arguments (empty
%options_and_callbacks), then it will create a parser that provides
version 2 compatibility mode callbacks.  See L</VERSION 2 COMPATIBILITY>.

=item $p->parse( $string )

Parse $string as the next chunk of the HTML document.  The return
value is a reference to the parser object (i.e. $p).

=item $p->eof

Signals the end of the HTML document.  Calling the eof() method will
flush any remaining buffered text.  The return value is a reference to
the parser object.

=item $p->parse_file( $file )

This method can be called to parse text directly from a file.  The
$file argument can be a filename or an open file handle (or
a reference to such a handle).

If $file is a plain filename and the file can't be opened, then the
method will return an undefined value and $! will tell you why it
failed.  Otherwise the return value will be a reference to the parser
object.

If a filehandle is passed as the $file argument, then the file will
be read until EOF, but not closed.

=item $p->callback( event => \&subroutine )

This method assigns a subroutine (which may be an anonymous
subroutine) as the callback for an event.  Event is one of C<text>,
C<start>, C<end>, C<declaration>, C<comment>, C<process> or
C<default>.  Look at L</HANDLERS> for details of when handlers are
called and the arguments passed to them.

=item $p->accum( $array_ref )

This method tells the parser to not make callbacks but instead append
entries to the array given as tokens are recognized.

[XXX Describe how tokens are reported (similar to HTML::TokeParser)]

  ["S",  $tag, \@attr, $origtext]
  ["E",  $tag, $origtext]
  ["T",  $text, $cdata]
  ["C",  $text]
  ["D",  $tokens, $origtext]
  ["PI", $text, $origtext]

=back


=head1 PARSER OPTIONS

Most parser options are controlled by boolean parser attributes.
Each boolean attribute is enabled by calling the corresponding method
with a TRUE argument and disabled with a FALSE argument.  The
attribute value is left unchanged if no argument is given.  The return
value from each method is the old attribute value.

The methods that can be used to get and/or set the options are:

=over

=item $p->strict_comment( [$bool] )

By default, comments are terminated by the first occurrence of "-->".
This is the behaviour of most popular browsers (like Netscape and
MSIE), but it is not correct according to the "official" HTML
standards.  Officially you need an even number of "--" tokens before
the closing ">" is recognized (and there can't be anything but
whitespace between an even and an odd "--")

The official behaviour is enabled by enabling this attribute.

=item $p->strict_names( [$bool] )

By default, almost anything is allowed in tag and attribute names.
This is the behaviour of most popular browsers and allows us to parse
some broken tags with invalid attr values like:

   <IMG SRC=newprevlstGr.gif ALT=[PREV LIST] BORDER=0>

By default, "LIST]" is parsed as the name of a boolean attribute, not as
part of the ALT value as was clearly intended.  This is also what
Netscape sees.

The official behaviour is enabled by enabling this attribute.  If
enabled it will cause a tag like the one above to be parsed as text
since "LIST]" is not a legal name.

=item $p->bool_attr_value( $val )

This method sets up the value reported for boolean attributes inside
HTML start tags.  By default the name of the attribute is also used as
its value.  The setting of $p>bool_attr_value has no effect when
$p->attr_pos is enabled.

=item $p->decode_text_entities( [$bool] )

When this attribute is enabled, HTML entity references (&amp;, &#255;,
...) are automatically decoded in the text reported.

=item $p->keep_case( [$bool] )

By default, tag and attr names are forced to lower case.  When this
attribute is enabled, the original text of the names is preserved.

Enabling $p->xml_mode also causes this behaviour even if the keep_case
value remains FALSE.

=item $p->xml_mode( [$bool] )

Enabling this attribute changes the parser to allow some XML
constructs such as empty element tags and XML processing instructions.  It
also disables forcing tag and attr names to lower case.

Empty element tags look like start tags, but end with the character
sequence "/>".  When recognized by HTML::Parser they cause an
artificial end tag to be generated in addition to the start tag.  The
$origtext of this generated end tag will be empty.

XML processing instructions are terminated by "?>" instead of a simple
">" as is the case for HTML.

=item $p->v2_compat( [$bool] )

Enabling this attribute causes start parameter reporting to be closer
to the behaviour of HTML::Parser v2.  More information in L</VERSION 2
COMPATIBILITY>.

=item $p->pass_self( [$bool] )

Enabling this attribute causes $self to be passed as the first
argument to callback subroutines.  Useful if the callback wants to
access attributes of the parser object or call methods on it.

If you register a closure with references to the parser as a handler,
then you create a circular reference that prevent the
parser from being garbage collected because the parser will have a
reference to the callback closure and the closure keeps an reference
to the parser.

[YYY Should this be implied by v2_compat? ]

=item $p->unbroken_text( [$bool] )

By default, blocks of text are given to the text handler as soon as
possible.  This might create arbitrary breaks that make it hard to do
transformations on the text. When this attribute is enabled blocks of
text are always returned in one piece.  This will delay the text
callback until the following (non-text) token has been recognized by
the parser.

=item $p->attr_pos( [$bool] )

By default start tag attributes are reported as key/value pairs in an
array passed to the C<start> handler.  When this attribute is enabled
a reference to an array of positions is substituted for the value.

The array elements are the offsets from the beginning of the tag text:

 (0) the character after the previous attribute
     or after the tag name if this is the first attribute,
 (1) the start of the attribute name,
 (2) the start of the attribute value (undef if no value), and
 (3) the character after the attribute

Examples of use:

 $pos = $attr->{bgcolor};
 if ($pos) {
    # these actions are mutually exclusive because $origtext is changed
    # kill any bgcolor attributes
    substr($origtext, $pos->[0], $pos->[3] - $pos->[0]) = "";

    # set value to yellow
    substr($origtext, $pos->[2], pos->[3] - $pos->[2]) = "yellow";

    # update attribute name
    substr($origtext, $pos->[1], length("bgcolor") = "x-bgcolor";
 }


=item $p->marked_section( [$bool] )

B<Note:> Access to this attribute will croak unless the I<Marked
Section option> was selected during module installation.

[YYY I think Marked Section support should not be optional. ]
[YYY What about parameter entities? ]

By default, section markings like <![CDATA[...]]> are treated like
ordinary text.  When this attribute is enabled section markings are
honoured.

More information about marked sections may be found in
C<http://www.sgml.u-net.com/book/sgml-8.htm>.

=back


=head1 HANDLERS

Callback subroutines may be assigned to events.  The association can
be made by providing <event>_cb options to the constructor,
as sub-options in the handlers option to the constructor,
or with the $p->callback method.

If $p->pass_self is enabled, the parser object will be passed as the
first argument to the handlers.

If $p->accum has been set, then handler callbacks will not be invoked.

=over

=item text( $text, $cdata_flag )

This subroutine is called when plain text is recognized.
The text may contain multiple lines.  A sequence of text
may be broken between several invocations of the text handler
unless $p->unbroken_text is enabled.

The parser will make sure that it does not break a word or a sequence
of spaces between two invocations of the text handler.

The $cdata_flag is FALSE if $text might contain general entity references that
have not yet been decoded.  If $p->decode_text_entities is enabled,
then the $cdata_flag will always be TRUE.  If $p->decode_text_entities
is disabled, then this flag will be true for text found inside CDATA
elements, like <script>, <style>, <xmp> and for CDATA marked sections.

When $cdata_flag is FALSE (or missing) then you should probably call
HTML::Entities::decode($text) before you process the text any further.

=item start( $tag, \@attr, $origtext )

This subroutine is called when a complete start tag is recognized.

The first argument is the tag name
(changed to lower case unless $p->keep_case has been enabled).

The second argument is a reference to an array that contains all
attributes found in the start tag.
Unless modified by certain parser options, attributes are represented by
key/value pairs.  The attribute keys are converted to lower case
unless $p->keep_case has been enabled.
Any general entities found in the attribute values are already decoded.

The third argument is the original text.

Example: 

The tag "<IMG src='smile.gif' IsMap>" is normally passed
to the start handler as:

  start("img",
        [src => "simle.gif", ismap => 'IsMap'],
        "<IMG src='smile.gif' IsMap>",
       );

If the $p->bool_attr_value("1") has been called it will be passed as:

  start("img",
        [src => "simle.gif", ismap => 1],
        "<IMG src='smile.gif' IsMap>",
       );

If the $p->attr_pos option has been enabled it will be passed as:

  start("img",
        [src   => [4, 5, 9, 20],
         ismap => [20, 21, undef, 26],
        ],
        "<IMG src='smile.gif' IsMap>",
       );


=item end( $tag, $origtext )

This subroutine is called when an end tag is recognized.

The first argument is the tag name
(changed to lower case unless $p->keep_case or $p->xml_mode has been enabled).

The second argument is the original text of the tag.


=item declaration( \@tokens, $origtext )

This subroutine is called when a I<markup declaration> is recognized.

For typical HTML documents, the only declaration you are
likely to find is <!DOCTYPE ...>.

Example:

  <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN"
  "http://www.w3.org/TR/html40/strict.dtd">

Will be passed as:

  declaration(['DOCTYPE', 'HTML', 'PUBLIC',
               '"-//W3C//DTD HTML 4.01//EN"',
               '"http://www.w3.org/TR/html40/strict.dtd"',
              ],
              '"<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN"
              "http://www.w3.org/TR/html40/strict.dtd">',
             );

Comments are also passed as separate tokens.

DTDs inside <!DOCTYPE ...> will confuse HTML::Parser.

=item comment( $comment )

This subroutine is called when a comment is recognized
that is not part of a declaration.
The leading and trailing "--" sequences have been stripped
from the comment text.

[XXX: Should there be an $origtext?  One problem is that if you turn
on $p->strict_comment, then a comment like this one <!-- foo -- -- bar
--> will be reported as two comments, and then $origtext does not make
sense.  This might be fixed by reporting this as one comment " foo --
-- bar ".  ]

[YYY Perhaps the two calls from parsing <!-- foo -- -- bar --> should call
   comment( ' foo ', '<!-- foo --' ) and
   comment( ' bar ', ' -- bar -->' )
I think it would be useful if all the document text that isn't
being ignored passes through an $origtext parameter. ]

=item process( $content, $origtext )

This subroutine is called when a processing instructions element is recognized.

The format and content of processing instructions is
system and application dependent.
More information about processing instructions may be found at
C<http://www.sgml.u-net.com/book/sgml-8.htm>.

=item default( $origtext )

This subroutine is called for anything that does not have a specific
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

[XXX I want this to be an HTML::Parser cookbook.  Also show how we
simplify the HTML recipes found in the "Perl Cookbook" with the new
features provided.]

=head1 SEE ALSO

L<HTML::Entities>, L<HTML::TokeParser>, L<HTML::Filter>,
L<HTML::HeadParser>, L<HTML::LinkExtor>

L<HTML::TreeBuilder> (part of the I<HTML-Tree> distribution)

=head1 COPYRIGHT

 Copyright 1996-1999 Gisle Aas. All rights reserved.
 Copyright 1999 Michael A. Chase.  All rights reserved.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
