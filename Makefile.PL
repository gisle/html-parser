require 5.004;
use strict;
use ExtUtils::MakeMaker;

my @extra;
my $ans = prompt("Do you want to compile with support for marked sections?", "no");
if ($ans =~ /^y(es)?$/i) {
    push(@extra, "DEFINE" => "-DMARKED_SECTION");
}

WriteMakefile(
    NAME	 => 'HTML::Parser',
    DISTNAME     => 'HTML-Parser-XS',
    VERSION_FROM => 'Parser.pm',
    H            => [ "hctype.h", "pfunc.h" ],
    @extra,
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);


sub MY::postamble
{
    '
pfunc.h : mkpfunc
	$(PERL) mkpfunc >pfunc.h

hctype.h : mkhctype
	$(PERL) mkhctype >hctype.h
'
}
