require 5.004;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME	 => 'HTML::Parser',
    VERSION_FROM => 'Parser.pm',
    dist         => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);
