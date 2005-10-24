require 5.005;
use strict;
use ExtUtils::MakeMaker;

if ($] eq "5.008") {
    die "The Unicode handling in perl-5.8.0 is too broken for HTML::Parser.
Please upgrade to a more recent version of perl-5.8.
";
}

WriteMakefile(
    NAME	 => 'HTML::Parser',
    VERSION_FROM => 'Parser.pm',
    H            => [ "hparser.h", "hctype.h", "tokenpos.h", "pfunc.h",
		      "hparser.c", "util.c",
		    ],
    PREREQ_PM    => {
		      'HTML::Tagset' => 3,
                    },
    DEFINE       => "-DMARKED_SECTION",
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean        => { FILES => 'hctype.h pfunc.h' },
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
