require 5.005;
use strict;
use ExtUtils::MakeMaker;

my @extra;
my @define;
my $ans = "y"; #prompt("Do you want to compile with support for marked sections?", "yes");
if ($ans =~ /^y(es)?$/i) {
    push(@define, "-DMARKED_SECTION");
}

push(@extra, "DEFINE" => "@define") if @define;


WriteMakefile(
    NAME	 => 'HTML::Parser',
    VERSION_FROM => 'Parser.pm',
    H            => [ "hparser.h", "hctype.h", "tokenpos.h", "pfunc.h",
		      "hparser.c", "util.c",
		    ],
    PREREQ_PM    => {
		      'HTML::Tagset' => 3,
                    },
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean        => { FILES => 'hctype.h pfunc.h' },
    @extra,
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
