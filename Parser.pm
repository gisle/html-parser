package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
# Copyright 1999, Michael A. Chase.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = 2.99_90;  # $Date: 1999/12/03 12:58:29 $

require HTML::Entities;

require DynaLoader;
@ISA=qw(DynaLoader);
HTML::Parser->bootstrap($VERSION);

sub new
{
    my $class = shift;
    my $self = bless {}, $class;
    _alloc_pstate($self);

    my %arg = @_;
    my $api_version = delete $arg{api_version} || (@_ ? 3 : 2);
    if ($api_version >= 4) {
	require Carp;
	Carp::croak("API version $api_version not supported by HTML::Parser $VERSION");
    }

    if ($api_version < 3) {
	# Set up method callbacks compatible with HTML-Parser-2.xx
	$self->handler(text    => "text",    "self,text,cdata_flag");
	$self->handler(end     => "end",     "self,tagname,text");
	$self->handler(process => "process", "self,token1,text");
	$self->handler(start   => "start",
		                  "self,tagname,attr,attrseq,text");

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
			   # MAC: should that be -3 instead of -1?
		       }, "self,text");
    }

    if (my $h = delete $arg{handlers}) {
	$h = {@$h} if ref($h) eq "ARRAY";
	while (my($event, $cb) = each %$h) {
	    $self->handler($event => $cb);
	}
    }

    # In the end we try to assume plain attribute or handler
    for (keys %arg) {
	if (/^(\w+)_h$/) {
	    $self->handler($1 => $arg{$_});
	}
	else {
	    $self->$_($arg{$_});
	}
    }

    return $self;
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
	warn "netscape_buggy_comment() is depreciated.  " .
	    "Please use the strict_comment() method instead";
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

This is the new XS based HTML::Parser.  It should be completely
backwards compatible with HTML::Parser version 2.2x, but has many new
features.  This is currently an beta release.  The interface to the
new features should now be fairly stable.

=head1 DESCRIPTION

The C<HTML::Parser> will tokenize an HTML document when the parse() or
parse_file() methods are called.  Tokens are reported by invoking
various event handlers.
The document to be parsed may be supplied in arbitrary chunks.


=head1 METHODS

=over

=item $p = HTML::Parser->new( %options_and_handlers )

The object constructor creates a new C<HTML::Parser> object and
returns it.  The constructor takes key/value arguments that can set up
event handlers or configure various options.

If the key ends with the suffix "_h" then it sets up a callback
handler, otherwise it simply assigns some plain attribute.
See </$p->handler>.

If new() is called without any arguments,
it will create a parser that uses callback methods compatible with Version 2.
See L</VERSION 2 COMPATIBILITY>.

Examples:

   $p = HTML::Parser->new(text_h => [ sub {...}, "dtext" ]);

This will create a new parser object, set up an text handler that receives
the original text with general entities decoded.  As an alternative you can
assign handlers like this:

  $p = HTML::Parser->new(handlers => { text => [sub {...}, "argspecs"],
                                       comment => [sub {...}, "argspecs"],
                                     });

=item $p->parse( $string )

Parse $string as the next chunk of the HTML document.
The return value is a reference to the parser object (i.e. $p).

=item $p->eof

Signals the end of the HTML document.
Calling the eof() method will flush any remaining buffered text.
The return value is a reference to the parser object.

=item $p->parse_file( $file )

This method can be called to parse text directly from a file.
The $file argument can be a filename or an open file handle
(or a reference to such a handle).

If $file is a plain filename and the file can't be opened, then the
method will return an undefined value and $! will tell you why it
failed.  Otherwise the return value will be a reference to the parser
object.

If a file handle is passed as the $file argument, then the file will
be read until EOF, but not closed.

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
MSIE), but it is not correct according to the official HTML
standard.  Officially you need an even number of "--" tokens before
the closing ">" is recognized and there may not be anything but
whitespace between an even and an odd "--".

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
enabled, it will the tag above to be parsed as text
since "LIST]" is not a legal name.

=item $p->bool_attr_value( $val )

This method sets the value reported for boolean attributes inside
HTML start tags.  By default, the name of the attribute is also used as
its value.

=item $p->xml_mode( [$bool] )

Enabling this attribute changes the parser to allow some XML
constructs such as empty element tags and XML processing instructions.
It also disables forcing tag and attr names to lower case when they
are reported by the C<tagname> and C<attr> argspecs.

Empty element tags look like start tags, but end with the character
sequence "/>".  When recognized by HTML::Parser they cause an
artificial end event in addition to the start event.  The
C<text> for this generated end event will be empty.

XML processing instructions are terminated by "?>" instead of a simple
">" as is the case for HTML.

=item $p->unbroken_text( [$bool] )

B<Note: This option is not supported yet!>

By default, blocks of text are given to the text handler as soon as
possible.  This might create arbitrary breaks that make it hard to do
transformations on the text. When this attribute is enabled, blocks of
text are always reported in one piece.  This will delay the text
event until the following (non-text) event has been recognized by
the parser.

=item $p->marked_section( [$bool] )

By default, section markings like <![CDATA[...]]> are treated like
ordinary text.  When this attribute is enabled section markings are
honoured.

More information about marked sections may be found in
C<http://www.sgml.u-net.com/book/sgml-8.htm>.

=back


=head1 HANDLERS

=over

=item $p->handler( event => \&subroutine, argspec )

=item $p->handler( event => method_name, argspec )

=item $p->handler( event => \@accum, argspec )

This method assigns a subroutine, method, or array to handle an event.

Event is one of C<text>, C<start>, C<end>, C<declaration>, C<comment>,
C<process> or C<default>.

Subroutine is a reference to a subroutine which is called to handle the event.

Method_name is the name of a method of $p which is called to handle the event.

Accum is an array that will hold the event information as sub-arrays.

Argspec is a string that describes the information reported by the
event.  Any requested information that does not apply to an event is
passed as undef.

Examples:

    $p->handler(start => "start", 'self,attr,attrseq,text');

This causes the "start" method of object $p to be called for 'start' events.
The callback signature is $p->start(\%attr, \@attr_seq, $orig_text).

    $p->handler(start => \&start, 'attr, attrseq, text');

This causes subroutine start() to be called for 'start' events.
The callback signature is start(\%attr, \@attr_seq, $orig_text).

    $p->handler(start => \@accum, '"start",attr,attrseq,text');

This causes 'start' event information to be saved in @accum.
The array elements will be ['start', \%attr, \@attr_seq, $orig_text].

=back

=head2 Argspec

Argspec is a string containing a comma separated list that describes
the information reported by the event.  The following names can be
used:

=over

=item self

Self causes the current object to be passed to the handler.
If the handler is a method, this must be the first element in the argspec.

=item tokens

Tokens causes a reference to an array of token strings to be passed.
The strings are exactly as they were found in the original text,
no decoding or case changes are applied.

For C<declaration> events, the array contains each word, comment, and
delimited string starting with the declaration type.

For C<comment> events, this contains each sub-comment.
If $p->strict_comments is disabled, there will be only one sub-comment.

For C<start> events, this contains the original tag name followed by
the attribute name/value pairs.

For C<end> events, this contains the original tag name.

For C<process> events, this contains the process instructions.

=item tokenpos

Tokenpos causes a reference to an array of token positions to be passed.
For each string that appears in C<tokens>, this array contains two numbers.
The first number is the offset of the start of the token in the original text
C<text> and the second number is the length of the token.

=item token1

Token1 causes the original text of the first token string to be passed.

For C<declaration> events, this is the declaration type.

For C<start> and C<end> events, this is the tag name.

This is undef if there is no first token in the event.

=item tagname

=item gi

Tagname and gi are identical to C<token1> except that
if $p->xml_mode is disabled, the tag name is forced to lower case.

=item attr

Attr causes a reference to a hash of attribute name/value pairs to be passed.

This is undef except for C<start> events.

If $p->xml_mode is disabled, the attribute names are forced to lower case.

General entities are decoded in the attribute values and
quotes around the attribute values are removed.

=item attrseq

Attrseq causes a reference to an array of attribute names to be passed.

This is undef except for C<start> events.

If $p->xml_mode is disabled, the attribute names are forced to lower case.

=item text

Text causes the original event text (including delimiters) to be passed.

=item dtext

Dtext causes the original text (including delimiters) to be passed.

This is undef except for C<text> events.

General entities are decoded unless the event was inside a CDATA section
or was between literal start and end tags
(C<script>, C<style>, C<xmp>, and C<plaintext>).

=item cdata_flag

Cdata_flag causes a TRUE value to be passed
if the event inside a CDATA section
or was between literal start and end tags
(C<script>, C<style>, C<xmp>, and C<plaintext>).

When the flag is FALSE for a text event, the you should either use
C<dtext> or decode the entities yourself before the text is
processed further.

=item event

Event causes the event name to be provided.

The event name is one of C<text>, C<start>, C<end>, C<declaration>,
C<comment>, C<process> or C<default>.

=back

=head2 Events

Handlers for the following events can be registered:

=over

=item text

This event is triggered when plain text is recognized.
The text may contain multiple lines.  A sequence of text
may be broken between several text events
unless $p->unbroken_text is enabled.

The parser will make sure that it does not break a word or a sequence
of spaces between two text events.

=item start

This event is triggered when a complete start tag is recognized.

=item end

This event is triggered when an end tag is recognized.

=item declaration

This event is triggered when a I<markup declaration> is recognized.

For typical HTML documents, the only declaration you are
likely to find is <!DOCTYPE ...>.

Example:

  <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN"
  "http://www.w3.org/TR/html40/strict.dtd">

DTDs inside <!DOCTYPE ...> will confuse HTML::Parser.

=item comment

This event is triggered when a markup comment is recognized.

=item process

This event is triggered when a processing instructions element is recognized.

The format and content of processing instructions is
system and application dependent.
More information about processing instructions may be found at
C<http://www.sgml.u-net.com/book/sgml-8.htm>.

=item default

This event is triggered for events that do not have a specific handler.

=back

=head1 VERSION 2 COMPATIBILITY

When an C<HTML::Parser> object is constructed with no arguments, a set
of handlers is provided that is compatible with the old HTML::Parser
Version 2 callback methods.

This is equivilent to the following method calls:

   $p->handler(text    => "text",    "self,text,cdata_flag");
   $p->handler(end     => "end",     "self,tagname,text");
   $p->handler(process => "process", "self,token1,text");
   $p->handler(start   => "start",   "self,tagname,attr,attrseq,text");
   $p->handler(comment =>
             sub {
		 my($self, $tokens) = @_;
		 for (@$tokens) {$self->comment($_);}},
             "self,tokens");
   $p->handler(declaration =>
             sub {
		 my $self = shift;
		 $self->declaration(substr($_[0], 2, -1));},
             "self,text");

=head1 EXAMPLES

Strip out <font> tags:

  sub ignore_font { print pop unless shift eq "font" }
  HTML::Parser->new(default_h => [sub { print shift }, 'text'],
                    start_h => [\&ignore_font, 'tagname,text'],
                    end_h => [\&ignore_font, 'tagname,text'],
		    marked_sections => 0,
		    )->parse_file(shift);

Strip out comments:

  HTML::Parser->new(default_h => [sub { print shift }, 'text'],
                    comment_h => [sub { }, ''],
                   )->parse_file(shift);

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
