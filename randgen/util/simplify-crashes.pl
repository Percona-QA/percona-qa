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

my $basedir = '/build/bzr/azalea/';
my $vardir = '/build/bzr/vardir1';
my $dsn = 'dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test';
my $original_query = "SELECT OUTR .`varchar_nokey`  AS X  FROM B  AS OUTR2  LEFT  JOIN C  AS OUTR  ON ( OUTR2 .`varchar_key`  <= OUTR .`varchar_key`  )  WHERE ( OUTR .`varchar_nokey`  , OUTR  )  IN (  SELECT INNR .`varchar_key`  AS X  , INNR .`varchar_key`  AS Y  FROM BB  AS INNR  WHERE INNR .`int_nokey`  > INNR .`int_key`  XOR OUTR .`int_nokey`  =  2  )  XOR OUTR .`int_key`  <  9  ORDER  BY OUTR .`date_key`  , OUTR .`pk`";

my $orig_database = 'test';
my $new_database = 'crash';

my $executor;
start_server();

my $simplifier = GenTest::Simplifier::SQL->new(
	oracle => sub {
		my $oracle_query = shift;
		my $oracle_result = $executor->execute($oracle_query);
		if ($oracle_result->status() == STATUS_SERVER_CRASHED) {
			start_server();
			return 1;	# Continues to crash
		} else {
			return 0;	# No longer crashes
		}
	}
);

my $simplified_query = $simplifier->simplify($original_query);
print "Simplified query:\n$simplified_query;\n\n";

my $simplifier_test = GenTest::Simplifier::Test->new(
	executors => [ $executor ],
	queries => [ $simplified_query , $original_query ]
);

my $simplified_test = $simplifier_test->simplify();

print "Simplified test\n\n";
print $simplified_test;

sub start_server {
	chdir($basedir.'/mysql-test') or die $!;
	system("MTR_VERSION=1 perl mysql-test-run.pl --skip-ndbcluster -start-and-exit --start-dirty --vardir=$vardir --master_port=19306 --mysqld=--init-file=/randgen/gentest/mysql-test/gentest/init/no_mrr.sql 1st");

	$executor = GenTest::Executor::MySQL->new(
		dsn => $dsn,
	);

	$executor->init();
}


