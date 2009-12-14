package GenTest::Validator::DatabaseConsistency;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

my $tables;
my $dbh;

sub validate {
	my ($validator, $executors, $results) = @_;
	my $dsn = $executors->[0]->dsn();

	foreach my $i (0..$#$results) {
		if ($results->[$i]->status() == STATUS_TRANSACTION_ERROR) {
#			say("Explicit rollback after query ".$results->[$i]->query());
			$executors->[$i]->dbh()->do("ROLLBACK /* Explicit ROLLBACK after a ".$results->[$i]->errstr()." error. */ ");
		}
	}

	$dbh = DBI->connect($dsn) if not defined $dbh;
	$tables = $dbh->selectcol_arrayref("SHOW TABLES") if not defined $tables;

	foreach my $table (@$tables) {
		my ($average1, $average2, $count) = $dbh->selectrow_array("
			SELECT
			AVG(`col_int_key`) + AVG(`col_int`) AS average1,
			(SUM(`col_int_key`) + SUM(`col_int`)) / COUNT(*) AS average2,
			COUNT(*) AS count
			FROM `$table`
		");

		if (($average1 eq '') && ($count eq '')) {
			# Server probably crashed, the SELECT returned no data
			return STATUS_UNKNOWN_ERROR;
		}

		if (($average1 ne '200.0000') || ($average2 ne '200.0000')) {
			say("Bad average for table: $table; average1: $average1; average2: $average2; count: $count; affected_rows: ".$results->[0]->affectedRows()."; query: ".$results->[0]->query());
			return STATUS_DATABASE_CORRUPTION;
		}
	}

	return STATUS_OK;
}

1;
