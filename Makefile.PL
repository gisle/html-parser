require 5.004;
use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME	 => 'HTML::Parser',
    DISTNAME     => 'HTML-Parser-XS',
    VERSION_FROM => 'Parser.pm',
    H            => [ "hctype.h", "pfunc.h" ],
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
