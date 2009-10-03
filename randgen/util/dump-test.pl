use strict;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest::Constants;
use GenTest::Executor::MySQL;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;

#
# Please modify those settings to fit your environment before you run this script
#

my @dsns = (
	'dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test',
	'dbi:mysql:host=127.0.0.1:port=19308:user=root:database=test'
);

my $query = "SELECT table1 .`varchar_key` field1  FROM B table1  JOIN C table2  ON table2 .`int_key`  WHERE table1 .`varchar_key`  = 'b' GROUP  BY field1";

my @executors;
my @results;

foreach my $dsn (@dsns) {
	my $executor = GenTest::Executor::MySQL->new(
		dsn => $dsn
	);
	$executor->init();
	push @executors, $executor;

	my $result = $executor->execute($query, 1);
	push @results, $result;
}

my $simplifier_test = GenTest::Simplifier::Test->new(
	executors => \@executors,
	queries => [ $query ],
	results => [ \@results ]
);

my $test = $simplifier_test->simplify();

print $test;
