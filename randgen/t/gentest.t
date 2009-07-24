use strict;
use lib 'lib';
use lib '../lib';

use GenTest::Constants;
use Test::More tests => 1;

my $exit_code = system("perl gentest.pl --dsn=dbi:mysql:host=127.0.0.1:port=12345:user=foo:database=bar --grammar=t/gensql.yy");
ok (($exit_code >> 8) == STATUS_ENVIRONMENT_FAILURE, 'gentest_baddsn');
