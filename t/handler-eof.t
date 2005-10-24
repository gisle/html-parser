use Test::More tests => 6;

use strict;
use HTML::Parser ();

my $p = HTML::Parser->new(api_version => 3);

$p->handler(start => sub { my $attr = shift; is($attr->{testno}, 1) },
		     "attr");
$p->handler(end => sub { shift->eof }, "self");
my $text;
$p->handler(text => sub { $text = shift }, "text");

is($p->parse("<foo testno=1>"), $p);

$text = '';
ok(!$p->parse("</foo><foo testno=999>"));
ok(!$text);

$p->handler(end => sub { $p->parse("foo"); }, "");
eval {
    $p->parse("</foo>");
};
like($@,  qr/Parse loop not allowed/);

# We used to get into an infinite loop if the eof triggered
# handler called ->eof

use HTML::Parser;
$p = HTML::Parser->new(api_version => 3);

my $i;
$p->handler("default" =>
	    sub {
		my $p=shift;
	        #++$i; diag "$i @_";
		$p->eof;
	    }, "self, event");
$p->parse("Foo");
$p->eof;

pass;
