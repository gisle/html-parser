package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = '2.99_01';  # $Date: 1999/11/03 20:59:34 $

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
    require HTML::Entities;

    $self->pass_cbdata(1);

    $self->callback(text        => sub { shift->text(@_)});
    $self->callback(end         => sub { shift->end(@_)});
    $self->callback(comment     => sub { shift->comment(@_)});
    $self->callback(declaration => sub { shift->declaration(reverse @_)});
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
	warn "netscape_buggy_comment() is depreciated.  Please use the strict_comment() method instead";
    }
    my $old = !$self->strict_comment;
    $self->strict_comment(!shift) if @_;
    return $old;
}


sub text { }
*declaration = \&text;
*comment     = \&text;
*start       = \&text;
*end         = \&text;

1;
