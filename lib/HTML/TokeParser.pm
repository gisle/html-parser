package HTML::TokeParser;

# $Id: TokeParser.pm,v 2.2 1998/07/08 11:12:59 aas Exp $

require HTML::Parser;
@ISA=qw(HTML::Parser);

use strict;
use Carp qw(croak);
use HTML::Entities qw(decode_entities);


sub new
{
    my $class = shift;
    my $file = shift;
    croak "Usage: $class->new(\$file)" unless defined $file;
    unless (ref $file) {
	require IO::File;
	$file = IO::File->new($file, "r") || croak "Can't open '$file': $!";
    }
    my $self = $class->SUPER::new;
    $self->{file} = $file;
    $self->{tokens} = [];
    $self->{textify} = {img => "alt", applet => "alt"};
    $self;
}

# Set up callback methods
for (qw(declaration start end text comment)) {
    my $t = uc(substr($_,0,1));
    no strict 'refs';
    *$_ = sub { my $self = shift; push(@{$self->{tokens}}, [$t, @_]) };
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


sub unget_token
{
    my $self = shift;
    unshift @{$self->{tokens}}, @_;
    $self;
}


sub get_next_tag
{
    my $self = shift;
    my $token;
  GET_TOKEN:
    {
	$token = $self->get_token;
	if ($token) {
	    my $type = shift @$token;
	    redo GET_TOKEN if $type !~ /^[SE]$/;
	    substr($token->[0], 0, 0) = "/" if $type eq "E";
	}
    }
    $token;
}


sub get_text
{
    my $self = shift;
    my $endat = shift;
    my @text;
    while (my $token = $self->get_token) {
	my $type = $token->[0];
	if ($type eq "T") {
	    push(@text, decode_entities($token->[1]));
	} elsif ($type =~ /^[SE]$/) {
	    my $tag = $token->[1];
	    if ($type eq "S") {
		if (exists $self->{textify}{$tag}) {
		    my $alt = $self->{textify}{$tag};
		    my $text;
		    if (ref($alt)) {
			$text = &$alt(@$token);
		    } else {
			$text = $token->[2]{$alt || "alt"};
			$text = "[\U$tag]" unless defined $text;
		    }
		    push(@text, $text);
		    next;
		}
	    } else {
		$tag = "/$tag";
	    }
	    if (!defined($endat) || $endat eq $tag) {
		 $self->unget_token($token);
		 last;
	    }
	}
    }
    join("", @text);
}


sub get_trimmed_text
{
    my $self = shift;
    my $text = $self->get_text(@_);
    $text =~ s/^\s+//; $text =~ s/\s+$//; $text =~ s/\s+/ /g;
    $text;
}

1;
