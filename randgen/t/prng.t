use strict;
use lib 'lib';
use lib '../lib';

use Test::More tests => 2;

use GenTest::Random;

my $prng = GenTest::Random->new(
	seed => 2
);

my $numbers = join(' ', map { $prng->digit() } (0..9));
ok($numbers eq '7 4 9 8 4 1 2 1 5 2', 'prng_stability');
ok($prng->date() eq '2000-07-14', 'prng_date');