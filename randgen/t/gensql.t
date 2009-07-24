use strict;
use lib 'lib';
use lib '../lib';

use GenTest::Constants;
use Test::More tests => 2;

open (GENSQL, "perl gensql.pl --grammar=t/gensql.yy --queries=1|");
my $output = <GENSQL>;
chop($output);
ok($output eq 'A ;  A;', 'gensql');

my $exit_code = system("perl gensql.pl --dsn=dbi:mysql:host=127.0.0.1:port=12345:user=foo:database=bar --grammar=t/gensql.yy");
ok (($exit_code >> 8) == STATUS_ENVIRONMENT_FAILURE, 'gensql_baddsn');
