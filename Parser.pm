package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = '2.99_11';  # $Date: 1999/11/17 19:57:01 $

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
	    local $@;
	    eval { $self->callback($_ => $cfg{$_}) };
	    if ($@) {
		if (my $m = $self->can($_)) {
		    &$m($self, $cfg{$_});
		}
		else {
		    warn "Unknown configuration key $_" if $^W;
		}
	    }
	}
    }
    else {
	# Set up method callbacks for compatibility with HTML-Parser-2.xx
	$self->pass_cbdata(1);  # get back $self as first argument
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
2.2x, but have many new features (not documented yet).  The rest of
this manual page describe HTML::Parser v2.25.

The C<HTML::Parser> will tokenize an HTML document when the parse() or
parse_file() methods are called.  Tokens are reported by invoking
various callback methods.  The document to be parsed can be supplied
in arbitrary chunks.

The methods that make up the external interface of the C<HTML::Parser>
are:

=over 4

=item $p = HTML::Parser->new

The object constructor takes no arguments.

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

=item $p->strict_comment( [$bool] )

By default we parse comments similar to how the popular browsers (like
Netscape and MSIE) do it.  This means that comments will always be
terminated by the first occurrence of "-->".  This is not correct
according to the "official" HTML standards.  The official behaviour
can be enabled by calling the strict_comment() method with a TRUE
argument.

The return value from strict_comment() is the old attribute value.

=back



In order to make the parser do anything interesting, you must make a
subclass where you override one or more of the following methods as
appropriate:

=over 4

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
expanded.  You should call HTML::Entities::decode($text) before you
process the text any further.

A sequence of text in the HTML document can be broken between several
invocations of $self->text.  The parser will make sure that it does
not break a word or a sequence of spaces between two invocations of
$self->text().

=item $self->comment($comment)

This method is called as comments are recognized.  The leading and
trailing "--" sequences have been stripped off the comment text.

=back

The default implementation of these methods do nothing, i.e., the
tokens are just ignored.

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
