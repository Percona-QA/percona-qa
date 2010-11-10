use strict;

use lib 'lib';
use GenTest::SimPipe::DatabaseObject;
use GenTest::SimPipe::Testcase;
use GenTest::SimPipe::Oracle::FullScan;
use GenTest;
use GenTest::Constants;
use DBI;
use Data::Dumper;

my $dsn = 'dbi:mysql:port=19300:user=root:host=127.0.0.1';

my $dbh = DBI->connect($dsn, undef, undef, { mysql_multi_statements => 1, RaiseError => 1 });

$dbh->do("USE test");

my %col_map = (
	'col_int_nokey'		=> 'f1',
	'col_int_key'		=> 'f2',
	'col_varchar_key'	=> 'f3',
	'col_varchar_nokey'	=> 'f4',
	'col_time_key'		=> 'f5',
	'col_time_nokey'	=> 'f6',
);

my $query = "SELECT count(table1.col_time_key) FROM t1 AS table1 JOIN ( t2 AS table2 JOIN t2 AS table3 ON table3.col_int_key <= table2.col_int_nokey ) ON table3.pk < table2.col_int_key;";

$dbh->do("
SET SESSION SQL_MODE='NO_ENGINE_SUBSTITUTION';
DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS t2;

SET SESSION optimizer_switch='index_condition_pushdown=off';
SET SESSION join_cache_level=5;
SET SESSION join_buffer_size=1;
SET SESSION mrr_buffer_size=100000;

DROP TABLE /*! IF EXISTS */ t1;
DROP TABLE /*! IF EXISTS */ t2;

CREATE TABLE t2 (
pk int(11),
col_int_nokey int(11),
col_int_key int(11),
col_time_key time,
col_varchar_key varchar(1) COLLATE latin1_swedish_ci,
PRIMARY KEY (pk),
KEY (col_int_key),
KEY (col_time_key),
KEY (col_varchar_key),
KEY (col_int_key)) ENGINE=Aria;
INSERT INTO t2 VALUES ('1','2','9','11:28:45','x');
INSERT INTO t2 VALUES ('17','9','3','12:57:46','t');
INSERT INTO t2 VALUES ('20','5','7','21:50:03','w');

DROP TABLE IF EXISTS t1;
CREATE TABLE t1 (
pk int(11),
col_int_nokey int(11),
col_int_key int(11),
col_time_key time,
col_varchar_key varchar(1) COLLATE latin1_swedish_ci,
PRIMARY KEY (pk),
KEY (col_int_key),
KEY (col_time_key),
KEY (col_varchar_key),
KEY (col_int_key)) ENGINE=Aria;
INSERT INTO t1 VALUES ('29','231','107','03:10:35','a');
");

my @table_objs;
my $table_names = $dbh->selectcol_arrayref("
	SELECT TABLE_NAME
	FROM INFORMATION_SCHEMA.TABLES
	WHERE TABLE_SCHEMA = 'test'
	ORDER BY TABLE_ROWS DESC
");

foreach my $table_name (@$table_names) {
	my $table_obj = GenTest::SimPipe::DatabaseObject::newFromDSN($dsn, $table_name);

	foreach my $column (@{$table_obj->columns()}) {
		$column->[COLUMN_NAME] = $col_map{$column->[COLUMN_NAME]} if exists $col_map{$column->[COLUMN_NAME]};
	}

	foreach my $key (@{$table_obj->keys()}) {
		$key->[KEY_COLUMN] = $col_map{$key->[KEY_COLUMN]} if exists $col_map{$key->[KEY_COLUMN]};
	}

	push @table_objs, $table_obj;
}

while (my ($old, $new) = each %col_map) {
	$query =~ s{$old}{$new}sgi;
}

my $testcase = GenTest::SimPipe::Testcase->new(
	mysqld_options => {
		'index_condition_pushdown' => 'off',
		'mrr_sort_keys'	=> 'off',
		'optimizer_use_mrr' => 'force',
		'join_cache_level' => 5,
		'join_buffer_size' => 1,
		'mrr_buffer_size' => 100000
	},
	db_objects => \@table_objs,
	queries => [ $query ]
);

my $oracle = GenTest::SimPipe::Oracle::FullScan->new( dsn => $dsn );

die "not reproducible" if $oracle->oracle($testcase) == ORACLE_ISSUE_NO_LONGER_REPEATABLE;

my $mysqld_options = $testcase->mysqldOptions();
foreach my $mysqld_option (keys %{$mysqld_options}) {
	my $saved_mysqld_option_value = $mysqld_options->{$mysqld_option};
	$mysqld_options->{$mysqld_option} = undef;
	if ($oracle->oracle($testcase) != ORACLE_ISSUE_STILL_REPEATABLE) {
		$mysqld_options->{$mysqld_option} = $saved_mysqld_option_value;
	}
}

foreach my $db_object (@{$testcase->dbObjects()}) {
	my $saved_db_object = $db_object;
	$db_object = undef;
	next if $oracle->oracle($testcase) == ORACLE_ISSUE_STILL_REPEATABLE;
	$db_object = $saved_db_object;

	foreach my $key (@{$db_object->keys()}) {
		my $saved_key = $key;
		$key = undef;
		if ($oracle->oracle($testcase) != ORACLE_ISSUE_STILL_REPEATABLE) {
			$key = $saved_key;
		}
	}

	foreach my $column (@{$db_object->columns()}) {
		my $saved_column = $column;

		$column = undef;
		next if $oracle->oracle($testcase) == ORACLE_ISSUE_STILL_REPEATABLE;
		$column = $saved_column;
		
		$column->[COLUMN_TYPE] = 'int'; $column->[COLUMN_COLLATION] = undef;
		next if $oracle->oracle($testcase) == ORACLE_ISSUE_STILL_REPEATABLE;
		$column = $saved_column;

		$column->[COLUMN_TYPE] = 'varchar'; $column->[COLUMN_COLLATION] = undef;
		next if $oracle->oracle($testcase) == ORACLE_ISSUE_STILL_REPEATABLE;
		$column = $saved_column;

	}

	foreach my $row (@{$db_object->data()}) {
		my $saved_row = $row;
		$row = undef;
		if ($oracle->oracle($testcase) != ORACLE_ISSUE_STILL_REPEATABLE) {
			$row = $saved_row;
		}
	}
}

foreach my $db_object (@{$testcase->dbObjects()}) {
	next if not defined $db_object;
	foreach my $row (@{$db_object->data()}) {
		next if not defined $row;
		foreach my $cell (values %$row) {
			next if not defined $cell || length($cell) == 1;
			my $saved_cell = $cell;
			foreach my $new_length (1,4,8,32,128) {
				last if length($saved_cell) < $new_length;
				$cell = substr($saved_cell, 0, $new_length);
				if ($oracle->oracle($testcase) !=ORACLE_ISSUE_STILL_REPEATABLE) {
					$cell = $saved_cell;
				} else {
					last;
				}
			}
		}
	}
}


print $testcase->toString();

die "final not reproducible" if $oracle->oracle($testcase) == ORACLE_ISSUE_NO_LONGER_REPEATABLE;
