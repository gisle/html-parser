#!perl -w

BEGIN {
    if ($] < 5.008) {
        print "1..0 # skipped: This perl does not support Unicode\n";
        exit;
    }
}

use strict;
use Test qw(plan ok);
use HTML::Parser;

plan tests => 97;

my @warn;
$SIG{__WARN__} = sub {
    push(@warn, $_[0]);
};

my @parsed;
my $p = HTML::Parser->new(
  api_version => 3,
  default_h => [\@parsed, 'event, text, dtext, offset, length, offset_end, column, tokenpos, attr'],
);

my $doc = "<title>\x{263A}</title><h1 id=\x{2600} f>Smile &#x263a</h1>";
ok(length($doc), 45);

$p->parse($doc)->eof;

#use Data::Dump; Data::Dump::dump(@parsed);

ok(@parsed, 8);
ok($parsed[0][0], "start_document");

ok($parsed[1][0], "start");
ok($parsed[1][1], "<title>");
ok(utf8::is_utf8($parsed[1][1]));
ok($parsed[1][3], 0);
ok($parsed[1][4], 7);

ok($parsed[2][0], "text");
ok(ord($parsed[2][1]), 0x263A);
ok($parsed[2][2], chr(0x263A));
ok($parsed[2][3], 7);
ok($parsed[2][4], 1);
ok($parsed[2][5], 8);
ok($parsed[2][6], 7);

ok($parsed[3][0], "end");
ok($parsed[3][1], "</title>");
ok($parsed[3][3], 8);
ok($parsed[3][6], 8);

ok($parsed[4][0], "start");
ok($parsed[4][1], "<h1 id=\x{2600} f>");
ok(join("|", @{$parsed[4][7]}), "1|2|4|2|7|1|9|1|0|0");
ok($parsed[4][8]{id}, "\x{2600}");

ok($parsed[5][0], "text");
ok($parsed[5][1], "Smile &#x263a");
ok($parsed[5][2], "Smile \x{263A}");

ok($parsed[7][0], "end_document");
ok($parsed[7][3], length($doc));
ok($parsed[7][5], length($doc));
ok($parsed[7][6], length($doc));
ok(@warn, 0);

# Try to parse it as an UTF8 encoded string
utf8::encode($doc);
ok(length($doc), 49);

@parsed = ();
$p->parse($doc)->eof;

#use Data::Dump; Data::Dump::dump(@parsed);

ok(@parsed, 8);
ok($parsed[0][0], "start_document");

ok($parsed[1][0], "start");
ok($parsed[1][1], "<title>");
ok(!utf8::is_utf8($parsed[1][1]));
ok($parsed[1][3], 0);
ok($parsed[1][4], 7);

ok($parsed[2][0], "text");
ok(ord($parsed[2][1]), 226);
ok($parsed[2][1], "\xE2\x98\xBA");
ok($parsed[2][2], "\xE2\x98\xBA");
ok($parsed[2][3], 7);
ok($parsed[2][4], 3);
ok($parsed[2][5], 10);
ok($parsed[2][6], 7);

ok($parsed[3][0], "end");
ok($parsed[3][1], "</title>");
ok($parsed[3][3], 10);
ok($parsed[3][6], 10);

ok($parsed[4][0], "start");
ok($parsed[4][1], "<h1 id=\xE2\x98\x80 f>");
ok(join("|", @{$parsed[4][7]}), "1|2|4|2|7|3|11|1|0|0");
ok($parsed[4][8]{id}, "\xE2\x98\x80");

ok($parsed[5][0], "text");
ok($parsed[5][1], "Smile &#x263a");
ok($parsed[5][2], "Smile \x{263A}");

ok($parsed[7][0], "end_document");
ok($parsed[7][3], length($doc));
ok($parsed[7][5], length($doc));
ok($parsed[7][6], length($doc));

ok(@warn, 1);
ok($warn[0] =~ /^Parsing of undecoded UTF-8 will give garbage when decoding entities/);

my $file = "test-$$.html";
open(my $fh, ">:utf8", $file) || die;
print $fh <<EOT;
\x{FEFF}
<title>\x{263A} Love! </title>
<h1 id=&hearts\x{2665}>&hearts Love \x{2665}<h1>
EOT
close($fh) || die;

@warn = ();
@parsed = ();
$p->parse_file($file);
ok(@parsed, "11");
ok($parsed[6][0], "start");
ok($parsed[6][8]{id}, "\x{2665}\xE2\x99\xA5");
ok($parsed[7][0], "text");
ok($parsed[7][1], "&hearts Love \xE2\x99\xA5");
ok($parsed[7][2], "\x{2665} Love \xE2\x99\xA5");  # expected garbage
ok($parsed[10][3], -s $file);
ok(@warn, 1);
ok($warn[0] =~ /^Parsing of undecoded UTF-8 will give garbage when decoding entities/);

@warn = ();
@parsed = ();
open($fh, "<:utf8", $file) || die;
$p->parse_file($fh);
ok(@parsed, "11");
ok($parsed[6][0], "start");
ok($parsed[6][8]{id}, "\x{2665}\x{2665}");
ok($parsed[7][0], "text");
ok($parsed[7][1], "&hearts Love \x{2665}");
ok($parsed[7][2], "\x{2665} Love \x{2665}");
ok($parsed[10][3], (-s $file) - 2 * 4);
ok(@warn, 0);

@warn = ();
@parsed = ();
open($fh, "<:raw", $file) || die;
$p->utf8_mode(1);
$p->parse_file($fh);
ok(@parsed, "11");
ok($parsed[6][0], "start");
ok($parsed[6][8]{id}, "\xE2\x99\xA5\xE2\x99\xA5");
ok($parsed[7][0], "text");
ok($parsed[7][1], "&hearts Love \xE2\x99\xA5");
ok($parsed[7][2], "\xE2\x99\xA5 Love \xE2\x99\xA5");
ok($parsed[10][3], -s $file);
ok(@warn, 0);

unlink($file);

ok(!HTML::Entities::_probably_utf8_chunk(""));
ok(!HTML::Entities::_probably_utf8_chunk("f"));
ok(HTML::Entities::_probably_utf8_chunk("f\xE2\x99\xA5"));
ok(HTML::Entities::_probably_utf8_chunk("f\xE2\x99\xA5o"));
ok(HTML::Entities::_probably_utf8_chunk("f\xE2\x99\xA5o\xE2"));
ok(HTML::Entities::_probably_utf8_chunk("f\xE2\x99\xA5o\xE2\x99"));
ok(!HTML::Entities::_probably_utf8_chunk("f\xE2"));
ok(!HTML::Entities::_probably_utf8_chunk("f\xE2\x99"));

