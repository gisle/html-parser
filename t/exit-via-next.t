# This give me a core dump for HTML::Parser 2.99_93 and perl5.003_05

print "1..1\n";
END { print "ok 1\n"; }

use HTML::Parser;
my $p = HTML::Parser->new(api_version => 3,
			  start_h => [sub {next}, ""],
			 );
$count = 0;
while ($count++ < 1) {
    $p->parse("<a href='foo'>bar</a>");
}
$p->eof;
$p = undef;
