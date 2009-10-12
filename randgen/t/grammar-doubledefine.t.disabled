use strict;
use lib 'lib';
use lib '../lib';


use Data::Dumper;
use GenTest::Grammar;
use GenTest::Generator::FromGrammar;

use Test::More tests => 2;

my $grammar = GenTest::Grammar->new(
	grammar_string => '
		query: definition1;
		query: definition2;
	'
);

ok((not defined $grammar), 'grammar_doubledefine');

my $generator = GenTest::Generator::FromGrammar->new(
	grammar_file => 't/grammar-doubledefine.yy'
);

ok((not defined $generator), 'generator_doubledefine');
