#!perl -w

use strict;
use Test qw(plan ok);

plan tests => 9;

use HTML::Entities qw(_decode_entities);

eval {
    _decode_entities("&lt;", undef);
};
ok($@ && $@ =~ /^Can't inline decode readonly string/);

eval {
    my $a = "";
    _decode_entities($a, $a);
};
ok($@ && $@ =~ /^2nd argument must be hash reference/);

eval {
    my $a = "";
    _decode_entities($a, []);
};
ok($@ && $@ =~ /^2nd argument must be hash reference/);

$a = "&lt;";
_decode_entities($a, undef);
ok($a, "&lt;");

_decode_entities($a, { "lt" => "<" });
ok($a, "<");

my $x = "x" x 20;

my $err;
for (":", ":a", "a:", "a:a", "a:a:a", "a:::a") {
    my $a = $_;
    $a =~ s/:/&a;/g;
    my $b = $_;
    $b =~ s/:/$x/g;
    _decode_entities($a, { "a" => $x });
    if ($a ne $b) {
	print "Something went wrong with '$_'\n";
	$err++;
    }
}
ok(!$err);

$a = "foo&nbsp;bar";
_decode_entities($a, \%HTML::Entities::entity2char);
ok($a, "foo\xA0bar");

$a = "foo&nbspbar";
_decode_entities($a, \%HTML::Entities::entity2char);
ok($a, "foo&nbspbar");

_decode_entities($a, \%HTML::Entities::entity2char, 1);
ok($a, "foo\xA0bar");
