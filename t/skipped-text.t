print "1..1\n";

use HTML::Parser;

my $p = HTML::Parser->new(api_version => 3);

$p->report_tags("a");

my @doc;

$p->handler(start => \&a_handler, "skipped_text, text");
$p->handler(end_document => \@doc, '@{skipped_text}');

$p->parse(<<EOT)->eof;
<title>hi<title>
<h1><a href="foo">link</a></h1>
and <a foo="">some</a> text.
EOT

sub a_handler {
    push(@doc, shift);
    my $text = shift;
    push(@doc, uc($text));
}


print "not " unless join("", @doc) eq <<'EOT'; print "ok 1\n";
<title>hi<title>
<h1><A HREF="FOO">link</a></h1>
and <A FOO="">some</a> text.
EOT

