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

my $basedir = '/build/bzr/azalea-perfschema';
my $vardir = '/build/bzr/azalea-perfschema/mysql-test/var';
my $dsn = 'dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test';
my $original_query = " SELECT * FROM (`information_schema` . `COLUMNS` AS table1 INNER JOIN `performance_schema` . `PROCESSLIST` AS table2 ON ( table2 . `ID` = table1 . `ORDINAL_POSITION` ) ) WHERE  table1 . `COLUMN_KEY` = table2 . `ID`   ORDER BY table1 . `TABLE_CATALOG` , table1 . `COLUMN_TYPE`";

my @mtr_options = (
	'--start-and-exit',
	'--start-dirty',
	"--vardir=$vardir",
	"--master_port=19306",
	"--mysqld=--init-file=/randgen/gentest/mysql-test/gentest/init/no_mrr.sql",
	'--skip-ndbcluster',
	'1st'	# Required for proper operation of MTR --start-and-exit
);

my $orig_database = 'test';
my $new_database = 'crash';

my $executor;
start_server();

my $simplifier = GenTest::Simplifier::SQL->new(
	oracle => sub {
		my $oracle_query = shift;
		my $oracle_result = $executor->execute($oracle_query);
		if (
			($oracle_result->status() == STATUS_SERVER_CRASHED) ||
			(!$executor->dbh()->ping())
                ) {
			start_server();
			return ORACLE_ISSUE_STILL_REPEATABLE;
		} else {
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
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
	system("MTR_VERSION=1 perl mysql-test-run.pl ".join(" ", @mtr_options));

	$executor = GenTest::Executor::MySQL->new( dsn => $dsn );

	$executor->init();
}


