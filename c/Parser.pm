package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = '2.99_01';  # $Date: 1999/11/03 20:46:41 $

require DynaLoader;
@ISA=qw(DynaLoader);
HTML::Parser->bootstrap($VERSION);

sub new
{
    my $class = shift;
    my $self = bless {}, $class;
    _alloc_pstate($self);
    if (@_) {
	while (@_) {
	    my $attr = shift;
	    my $callback = shift;
	    $self->callback($attr, $callback);
	}
    }
    else {
	_set_up_method_callbacks($self);
    }
    $self;
}

sub _set_up_method_callbacks
{
    my $self = shift;
    for (qw(text end declaration comment)) {
	my $meth = $_;
	$self->callback($_ => sub { shift->$meth(@_) });
    }
    require HTML::Entities;
    $self->callback(start =>
		   sub {
		       my($obj, $tag, $attr, $orig) = @_;
		       my(%attr, @seq);
		       while (@$attr) {
			   my $key = shift @$attr;
			   my $val  = HTML::Entities::decode(shift @$attr);
			   $attr{$key} = $val;
			   push(@seq, $key);
		       }
		       $obj->start($tag, \%attr, \@seq, $orig);
		   });
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
        $opened++;
        $file = *F;
    }
    my $chunk = '';
    while(read($file, $chunk, 512)) {
        $self->parse($chunk);
    }
    close($file) if $opened;
    $self->eof;
}

sub netscape_buggy_comment  # legacy
{
    my $self = shift;
    if ($^W) {
	warn "netscape_buggy_comment is depreciated.  Please use the strict_comment() method instead";
    }
    my $old = !$self->strict_comment;
    $self->strict_comment(!shift) if @_;
    return $old;
}

sub text
{
    # my($self, $text) = @_;
}

sub declaration
{
    # my($self, $decl) = @_;
}

sub comment
{
    # my($self, $comment) = @_;
}

sub start
{
    # my($self, $tag, $attr, $attrseq, $origtext) = @_;
    # $attr is reference to a HASH, $attrseq is reference to an ARRAY
}

sub end
{
    # my($self, $tag, $origtext) = @_;
}

1;
