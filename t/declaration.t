use Test::More tests => 1;

use HTML::Parser;
my $res = "";

sub decl
{
    my $t = shift;
    $res .= "[" . join("\n", map "<$_>", @$t) . "]";
}

sub text
{
    $res .= shift;
}

my $p = HTML::Parser->new(declaration_h => [\&decl, "tokens"],
			  default_h     => [\&text, "text"],
	                 );

$p->parse(<<EOT)->eof;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" --<comment>--
  "http://www.w3.org/TR/html40/strict.dtd">

<!ENTITY foo "<!-- foo -->">
<!Entity foo "<!-- foo -->">

<!row --> foo
EOT

is($res, <<EOT);
[<DOCTYPE>
<HTML>
<PUBLIC>
<"-//W3C//DTD HTML 4.01//EN">
<--<comment>-->
<"http://www.w3.org/TR/html40/strict.dtd">]

[<ENTITY>
<foo>
<"<!-- foo -->">]
[<Entity>
<foo>
<"<!-- foo -->">]

<!row --> foo
EOT
