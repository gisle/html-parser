eval {
   require HTTP::Headers;
};
if ($@) {
   print "1..0\n";
   print $@;
   exit;
}

print "1..1\n";

require HTML::HeadParser;

$h = HTTP::Headers->new;
$p = HTML::HeadParser->new($h);
$p->parse(<<EOT);
<title>Stupid example</title>
<base href="http://www.sn.no/libwww-perl/">
Normal text starts here.
EOT
undef $p;
print $h->title;   # should print "Stupid example"

print "not " unless $h->title eq "Stupid example";
print "ok 1\n";

