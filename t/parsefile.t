print "1..5\n";

my $filename = "file$$.htm";
open(FILE, ">$filename") || die;

my $testno = 1;

print FILE <<'EOT';
<title>Heisan</title>
EOT
close(FILE);

{
    package MyParser;
    require HTML::Parser;
    @ISA=qw(HTML::Parser);

    sub start
    {
	my($self, $tag, $attr) = @_;
	print "not " unless $tag eq "title";
	print "ok $testno\n";
	$testno++;
    }
}

MyParser->new->parse_file($filename);
open(FILE, $filename) || die;
MyParser->new->parse_file(*FILE);
seek(FILE, 0, 0) || die;
MyParser->new->parse_file(\*FILE);
close(FILE);

require IO::File;
my $io = IO::File->new($filename) || die;
MyParser->new->parse_file($io);
$io->seek(0, 0) || die;
MyParser->new->parse_file(*$io);
undef($io);

unlink($filename);
