package HTML::LineParser;

require HTML::Parser;
@ISA=qw(HTML::Parser);

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->lineno(1);
    $self;
}

sub parse
{
    my $self = shift;
    return $self->SUPER::parse($_[0]) unless defined $_[0];

    my @lines = split(/(\n)/, $_[0]);
    for (@lines) {
	$self->SUPER::parse($_);
	$self->{_lineno}++ if $_ eq "\n";
    }
    $self;
}

sub lineno
{
    my $self = shift;
    my $old = $self->{_lineno};
    $self->{_lineno} = shift if @_;
    $old;
}

1;
