package HTML::PullParser;

# $Id: PullParser.pm,v 2.1 2001/03/26 00:32:51 gisle Exp $

require HTML::Parser;
@ISA=qw(HTML::Parser);
$VERSION = sprintf("%d.%02d", q$Revision: 2.1 $ =~ /(\d+)\.(\d+)/);

use strict;
use Carp ();

sub new
{
    my $class = shift;
    my %cnf = (@_ == 1) ? (file => $_[0]) : @_;

    # Construct argspecs for the various events
    my %argspec;
    for (qw(start end text declaration comment process default)) {
	my $tmp = delete $cnf{$_};
	next unless defined $tmp;
	$argspec{$_} = $tmp;
    }

    my $file = delete $cnf{file};
    Carp::croak("Usage: $class->new(\$file)")
	  unless defined $file;

    if (!ref($file) && ref(\$file) ne "GLOB") {
	require IO::File;
	$file = IO::File->new($file, "r") || return;
    }

    # Create object
    $cnf{api_version} = 3;
    my $self = $class->SUPER::new(%cnf);

    my $accum = $self->{pullparser_accum} = [];
    while (my($event, $argspec) = each %argspec) {
	$self->SUPER::handler($event => $accum, $argspec);
    }

    if (ref($file) eq "SCALAR") {
	if (!defined $$file) {
	    Carp::carp("HTML::PullParser got undefined value as document")
		if $^W;
	    $self->{pullparser_eof}++;
	}
	else {
	    $self->{pullparser_scalar} = $file;
	    $self->{pullparser_scalarpos}  = 0;
	}
    }
    else {
	$self->{pullparser_file} = $file;
    }
    $self;
}


sub handler
{
    Carp::croak("Can't set handlers for HTML::PullParser");
}


sub get_token
{
    my $self = shift;
    while (!@{$self->{pullparser_accum}} && !$self->{pullparser_eof}) {
	if (my $f = $self->{pullparser_file}) {
	    # must try to parse more from the file
	    my $buf;
	    if (read($f, $buf, 512)) {
		$self->parse($buf);
	    } else {
		$self->eof;
		$self->{pullparser_eof}++;
		delete $self->{pullparser_file};
	    }
	}
	elsif (my $sref = $self->{pullparser_scalar}) {
	    # must try to parse more from the scalar
	    my $pos = $self->{pullparser_scalarpos};
	    my $chunk = substr($$sref, $pos, 512);
	    $self->parse($chunk);
	    $pos += length($chunk);
	    if ($pos < length($$sref)) {
		$self->{pullparser_scalarpos} = $pos;
	    }
	    else {
		$self->eof;
		$self->{pullparser_eof}++;
		delete $self->{pullparser_scalar};
		delete $self->{pullparser_scalarpos};
	    }
	}
	else {
	    die;
	}
    }
    shift @{$self->{pullparser_accum}};
}


sub unget_token
{
    my $self = shift;
    unshift @{$self->{pullparser_accum}}, @_;
    $self;
}

1;


__END__

=head1 NAME

HTML::PullParser - Alternative HTML::Parser interface

=head1 SYNOPSIS

 use HTML::PullParser;

 $p = HTML::TokeParser->new(file => "index.html",
                            start => "event, tag",
                            end   => "event, tag",
                           ) || die "Can't open: $!";
 while (my $token = $p->get_token) {
     #...
 }

=head1 DESCRIPTION

The HTML::PullParser is an alternative interface to the HTML::Parser class.
It basically turns the HTML::Parser inside out.  You associate a file
(or any IO::Handle object or string) with the parser at construction time and
then repeatedly call $parser->get_token to obtain the tags and text
found in the parsed document.

Methods: ...

=head1 SEE ALSO

L<HTML::Parser>, L<HTML::TokeParser>

=head1 COPYRIGHT

Copyright 1998-2001 Gisle Aas.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
