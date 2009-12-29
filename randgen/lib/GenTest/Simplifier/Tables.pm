package GenTest::Simplifier::Tables;

require Exporter;
use DBI;
use GenTest;
use Data::Dumper;

@ISA = qw(GenTest);

use strict;

use lib 'lib';

use constant SIMPLIFIER_DSN		=> 0;
use constant SIMPLIFIER_ORIG_DATABASE	=> 1;
use constant SIMPLIFIER_NEW_DATABASE	=> 2;

1;

sub new {
        my $class = shift;

	my $simplifier = $class->SUPER::new({
		dsn		=> SIMPLIFIER_DSN,
		orig_database	=> SIMPLIFIER_ORIG_DATABASE,
		new_database	=> SIMPLIFIER_NEW_DATABASE,
	}, @_);

	return $simplifier;
}

sub simplify {
	my ($simplifier, $initial_query) = @_;

	my $orig_database = $simplifier->[SIMPLIFIER_ORIG_DATABASE];
	my $new_database = $simplifier->[SIMPLIFIER_NEW_DATABASE];

	my @tables_named = $initial_query =~ m{(table[a-z0-9_]*)}sgio;
	my @tables_quoted = $initial_query =~ m{`(.*?)`}sgio;
	my @tables_letters = $initial_query =~ m{[ `]([A-Z]{1,3})[ `]}sgo;
	
	my @participating_tables = (@tables_named, @tables_quoted, @tables_letters);
	my %participating_tables;

	my @fields_quoted = $initial_query =~ m{`(.*?)`}sgio;
	my @fields_named = $initial_query =~ m{((?:char|varchar|int|set|enum|blob|date|time|datetime|pk)(?:`|\s|_key|_nokey))}sgo;

	my @participating_fields = (@fields_quoted, @fields_named);
	my %participating_fields;
	map { $participating_fields{$_} = 1 } @participating_fields;

	my $dbh = DBI->connect($simplifier->[SIMPLIFIER_DSN]);

	$dbh->do("DROP DATABASE IF EXISTS $new_database");
	$dbh->do("CREATE DATABASE $new_database");

	foreach my $participating_table (@participating_tables) {
		my ($table_exists) = $dbh->selectrow_array("SHOW TABLES IN $orig_database LIKE '$participating_table'");
		next if not defined $table_exists;
		next if exists $participating_tables{$participating_table};
		$participating_tables{$participating_table} = 1;
		$dbh->do("CREATE TABLE $new_database . $participating_table LIKE $orig_database . `$participating_table`");
		$dbh->do("INSERT INTO $new_database . $participating_table SELECT * FROM $orig_database . `$participating_table`");

        ## Find all fields in table
		my $actual_fields = $dbh->selectcol_arrayref("SHOW FIELDS FROM `$participating_table` IN $new_database");
        ## Find indexed fields in table
        my %indices;
        map {$indices{$_->[4]}=$_->[2]} @{$dbh->selectall_arrayref("SHOW INDEX FROM `$participating_table` IN $new_database")};

        ## Calculate which fields to keep
        my %keep;
		foreach my $actual_field (@$actual_fields) {
            if (not exists $participating_fields{$actual_field}) {
                ## Not used field, but may be part of multi-column index where other column is used
                if (exists $indices{$actual_field}) {
                    foreach my $x (keys %indices) {
                        $keep{$actual_field} = 1 
                            if (exists $participating_fields{$x}) and
                            ($indices{$x} eq $indices{$actual_field});
                    }
                }
            } else {
                ## Explicitely used field
                $keep{$actual_field}=1;
            }
        }

        ## Remove the fields we do not want to keep
		foreach my $actual_field (@$actual_fields) {
			$dbh->do("ALTER TABLE $new_database . `$participating_table` DROP COLUMN `$actual_field`") if not $keep{$actual_field};
        }
	}

	return keys %participating_tables;
}

1;
