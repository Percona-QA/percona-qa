use strict;
use lib 'lib';
use lib '../lib';

use Test::More tests => 1;

use GenTest::Random;

my $prng = GenTest::Random->new(
	seed => 2
);

my $numbers = join(' ', map { $prng->digit() } (0..9));
ok($numbers eq '3 0 5 4 4 7 2 5 7 8', 'prng_stability');
