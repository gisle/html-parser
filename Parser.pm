package HTML::Parser;

# Copyright 1996-1999, Gisle Aas.
#
# This library is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use vars qw($VERSION @ISA);

$VERSION = '2.99_09';  # $Date: 1999/11/11 09:15:22 $

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
