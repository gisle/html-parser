#!perl

use strict;
use warnings;

use Test::More tests => 1;

use HTML::Parser;

my $p;
$p = HTML::Parser->new(
    start_h => [sub {
   undef $p;
    }],
);

$p->parse(q(<foo>));

pass 'no SEGV';