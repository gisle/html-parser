use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME	 => 'HTML::Parser',
    VERSION_FROM => 'Parser.pm',
    ABSTRACT_FROM => 'Parser.pm',
    AUTHOR       => 'Gisle Aas <gisle@activestate.com>',
    LICENSE	 => 'perl',

    MIN_PERL_VERSION => 5.008,
    PREREQ_PM    => {
		      'HTML::Tagset' => 3,
		      'XSLoader' => 0,
                    },
    META_MERGE   => {
        build_requires => { 'Test::More' => 0 },
        recommends => { 'HTTP::Headers' => 0 },
        resources => {
            repository => 'http://github.com/gisle/html-parser',
	    MailingList => 'mailto:libwww@perl.org',
        }
    },

    DEFINE       => "-DMARKED_SECTION",
    H            => [ "hparser.h", "hctype.h", "tokenpos.h", "pfunc.h",
		      "hparser.c", "util.c",
		    ],
    clean        => { FILES => 'hctype.h pfunc.h' },
);


sub MY::postamble
{
    '
pfunc.h : mkpfunc
	$(PERLRUN) mkpfunc >pfunc.h

hctype.h : mkhctype
	$(PERLRUN) mkhctype >hctype.h
'
}

BEGIN {
    # compatibility with older versions of MakeMaker
    my $developer = -f "MANIFEST.SKIP";
    my %mm_req = (
        LICENCE => 6.31,
        META_MERGE => 6.45,
        META_ADD => 6.45,
        MIN_PERL_VERSION => 6.48,
    );
    undef(*WriteMakefile);
    *WriteMakefile = sub {
        my %arg = @_;
        for (keys %mm_req) {
            unless (eval { ExtUtils::MakeMaker->VERSION($mm_req{$_}) }) {
                warn "$_ $@" if $developer;
                delete $arg{$_};
            }
        }
        ExtUtils::MakeMaker::WriteMakefile(%arg);
    };
}
