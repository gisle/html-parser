package HTML::Parser;

use strict;
use vars qw($VERSION @ISA);

$VERSION = '2.99_01';  # $Date: 1999/11/03 12:17:09 $

require DynaLoader;
@ISA=qw(DynaLoader);
HTML::Parser->bootstrap($VERSION);

1;
