package TokeParser;

require HTML::Parser;
@ISA=qw(HTML::Parser);

use strict;

use Carp qw(croak);

sub new
{
    my $class = shift;
    my $file = shift || croak "Usage: $class->new(<file>)";
    unless (ref $file) {
	require IO::File;
	$file = IO::File->new($file, "r") || croak "Can't open $file: $!";
    }
    my $self = $class->SUPER::new;
    $self->{file} = $file;
    $self->{tokens} = [];
    $self;
}

sub get_token
{
    my $self = shift;
    while (!@{$self->{tokens}} && $self->{file}) {
	# must try to parse more of the file
	my $buf;
	if (read($self->{file}, $buf, 512)) {
	    $self->parse($buf);
	} else {
	    $self->eof;
	    delete $self->{file};
	}
    }
    shift @{$self->{tokens}};
}

for (qw(declaration start end text comment)) {
    my $t = uc(substr($_,0,1));
    no strict 'refs';
    *$_ = sub { my $self = shift; push(@{$self->{tokens}}, [$t, @_]) };
}

1;
