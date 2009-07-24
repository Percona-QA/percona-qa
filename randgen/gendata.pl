#!/usr/bin/perl

$| = 1;
use strict;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use DBI;
use Getopt::Long;
use GenTest;
use GenTest::Random;

use constant FIELD_TYPE			=> 0;
use constant FIELD_CHARSET		=> 1;
use constant FIELD_COLLATION		=> 2;
use constant FIELD_SIGN			=> 3;
use constant FIELD_NULLABILITY		=> 4;
use constant FIELD_INDEX		=> 5;
use constant FIELD_AUTO_INCREMENT	=> 6;
use constant FIELD_SQL			=> 7;
use constant FIELD_INDEX_SQL		=> 8;
use constant FIELD_NAME			=> 9;

use constant TABLE_ROW		=> 0;
use constant TABLE_ENGINE	=> 1;
use constant TABLE_CHARSET	=> 2;
use constant TABLE_COLLATION	=> 3;
use constant TABLE_ROW_FORMAT	=> 4;
use constant TABLE_PARTITION	=> 5;
use constant TABLE_PK		=> 6;
use constant TABLE_SQL		=> 7;
use constant TABLE_NAME		=> 8;

use constant DATA_NUMBER	=> 0;
use constant DATA_STRING	=> 1;
use constant DATA_BLOB		=> 2;
use constant DATA_TEMPORAL	=> 3;

my ($config_file, $dbh, $engine, $help, $dsn, $rows, $varchar_len);
my $seed = 1;

my $opt_result = GetOptions(
	'help'	=> \$help,
	'config:s' => \$config_file,
	'dsn:s'	=> \$dsn,
	'seed=s' => \$seed,
	'engine:s' => \$engine,
	'rows=i' => \$rows,
	'varchar-length=i' => \$varchar_len
);

help() if not defined $opt_result || $help;
exit(1) if !$opt_result;

my $prng = GenTest::Random->new(
	seed => $seed eq 'time' ? time() : $seed,
	varchar_length => $varchar_len
);

$dbh = DBI->connect($dsn, undef, undef, { PrintError => 1 } ) if defined $dsn;

#  
# The configuration file is actually a perl script, so we read it by eval()-ing it
#  

my ($tables, $fields, $data); 			# Configuration as read from the config file.
my (@table_perms, @field_perms, @data_perms);	# Configuration after defaults have been substituted

if ($config_file ne '') {
	open(CONF , $config_file) or die "unable to open config file '$config_file': $!";
	read(CONF, my $config_text, -s $config_file);
	eval ($config_text);
	die "Unable to load $config_file: $@" if $@;
}

output("SET SQL_MODE='NO_ENGINE_SUBSTITUTION'");
output("SET STORAGE_ENGINE='$engine'") if $engine ne '';

$table_perms[TABLE_ROW] = $tables->{rows} || (defined $rows ? [ $rows ] : undef ) || [0, 1, 2, 10, 100];
$table_perms[TABLE_ENGINE] = $tables->{engines} || [ $engine ];
$table_perms[TABLE_CHARSET] = $tables->{charsets} || [ undef ];
$table_perms[TABLE_COLLATION] = $tables->{collations} || [ undef ];
$table_perms[TABLE_PARTITION] = $tables->{partitions} || [ undef ];
$table_perms[TABLE_PK] = $tables->{pk} || [ 'integer auto_increment' ];
$table_perms[TABLE_ROW_FORMAT] = $tables->{row_formats} || [ undef ];

$field_perms[FIELD_TYPE] = $fields->{types} || [ 'int', 'varchar', 'date', 'time', 'datetime' ];
$field_perms[FIELD_NULLABILITY] = $fields->{null} || $fields->{nullability} || [ undef ];
$field_perms[FIELD_SIGN] = $fields->{sign} || [ undef ];
$field_perms[FIELD_INDEX] = $fields->{indexes} || $fields->{keys} || [ undef, 'KEY' ];
$field_perms[FIELD_CHARSET] =  $fields->{charsets} || [ undef ];
$field_perms[FIELD_COLLATION] = $fields->{collations} || [ undef ];

$data_perms[DATA_NUMBER] = $data->{numbers} || ['digit', 'digit', 'digit', 'digit', 'null' ];	# 20% NULL values
$data_perms[DATA_STRING] = $data->{strings} || ['letter', 'letter', 'letter', 'letter', 'null' ];
$data_perms[DATA_BLOB] = $data->{blobs} || [ 'data', 'data', 'data', 'data', 'null' ];
$data_perms[DATA_TEMPORAL] = $data->{temporals} || [ 'date', 'time', 'datetime', 'year', 'timestamp', 'null' ];

my @tables = (undef);

foreach my $cycle (TABLE_ROW, TABLE_ENGINE, TABLE_CHARSET, TABLE_COLLATION, TABLE_PARTITION, TABLE_PK, TABLE_ROW_FORMAT ) {
	@tables = map {
		my $old_table = $_;
		if (not defined $table_perms[$cycle]) {
			$old_table;	# Retain old table, no permutations at this stage.
		} else {
			# Create several new tables, one for each allowed value in the current $cycle
			map {
				my $new_perm = $_;
				my @new_table = defined $old_table ? @$old_table : [];
				$new_table[$cycle] = lc($new_perm);
				\@new_table;
			} @{$table_perms[$cycle]};
		}
	} @tables;
}

#
# Iteratively build the array of tables. We start with an empty array, and on each iteration
# we increase the size of the array to contain more combinations.
# 
# Then we do the same for fields.
#

my @fields = (undef);

foreach my $cycle (FIELD_TYPE, FIELD_NULLABILITY, FIELD_SIGN, FIELD_INDEX, FIELD_CHARSET, FIELD_COLLATION) {
	@fields = map {
		my $old_field = $_;
		if (not defined $field_perms[$cycle]) {
			$old_field;	# Retain old field, no permutations at this stage.
		} elsif (
			($cycle == FIELD_SIGN) &&
			($old_field->[FIELD_TYPE] !~ m{int|float|double|dec|numeric|fixed}sio) 
		) {
			$old_field;	# Retain old field, sign does not apply to non-integer types
		} elsif (
			($cycle == FIELD_CHARSET) &&
			($old_field->[FIELD_TYPE] =~ m{bit|int|bool|float|double|dec|numeric|fixed|blob|date|time|year}sio)
		) {
			$old_field;	# Retain old field, charset does not apply to integer types
		} else {
			# Create several new fields, one for each allowed value in the current $cycle
			map {
				my $new_perm = $_;
				my @new_field = defined $old_field ? @$old_field : [];
				$new_field[$cycle] = lc($new_perm);
				\@new_field;
			} @{$field_perms[$cycle]};
		}
	} @fields;
}

# If no fields were defined, continue with just the primary key.
@fields = () if ($#fields == 0) && ($fields[0]->[FIELD_TYPE] eq '');

foreach my $field_id (0..$#fields) {
	my $field = $fields[$field_id];
	next if not defined $field;
	my @field_copy = @$field;

#	$field_copy[FIELD_INDEX] = 'nokey' if $field_copy[FIELD_INDEX] eq '';

	my $field_name;
	$field_name = join('_', grep { $_ ne '' } @field_copy);
	$field_name =~ s{[^A-Za-z0-9]}{_}sgio;
	$field_name =~ s{ }{_}sgio;
	$field_name =~ s{_+}{_}sgio;
	$field_name =~ s{_+$}{}sgio;

	$field->[FIELD_NAME] = $field_name;
	
	if (
		($field_copy[FIELD_TYPE] =~ m{set|enum}sio) &&
		($field_copy[FIELD_TYPE] !~ m{\(}sio )
	) {
		$field_copy[FIELD_TYPE] .= " (".join(',', map { "'$_'" } ('a'..'z') ).")";
	}
	
	if (
		($field_copy[FIELD_TYPE] =~ m{char}sio) &&
		($field_copy[FIELD_TYPE] !~ m{\(}sio)
	) {
		$field_copy[FIELD_TYPE] .= ' (1)';
	}

	$field_copy[FIELD_CHARSET] = "CHARACTER SET ".$field_copy[FIELD_CHARSET] if $field_copy[FIELD_CHARSET] ne '';
	$field_copy[FIELD_COLLATION] = "COLLATE ".$field_copy[FIELD_COLLATION] if $field_copy[FIELD_COLLATION] ne '';

	my $key_len;
	
	if (
		($field_copy[FIELD_TYPE] =~ m{blob|text}sio ) &&  
		($field_copy[FIELD_TYPE] !~ m{\(}sio )
	) {
		$key_len = " (255)";
	}

	if (
		($field_copy[FIELD_INDEX] ne 'nokey') &&
		($field_copy[FIELD_INDEX] ne '')
	) {
		$field->[FIELD_INDEX_SQL] = $field_copy[FIELD_INDEX]." (`$field_name` $key_len)";
	}

	delete $field_copy[FIELD_INDEX]; # do not include FIELD_INDEX in the field description

	$fields[$field_id]->[FIELD_SQL] = "`$field_name` ". join(' ' , grep { $_ ne '' } @field_copy);

	if ($field_copy[FIELD_TYPE] =~ m{timestamp}sio ) {
		$field->[FIELD_SQL] .= ' DEFAULT 0';
	}
}

foreach my $table_id (0..$#tables) {
	my $table = $tables[$table_id];
	my @table_copy = @$table;
	my $table_name;

	$table_name = "table".join('_', grep { $_ ne '' } @table_copy);
	$table_name =~ s{[^A-Za-z0-9]}{_}sgio;
	$table_name =~ s{ }{_}sgio;
	$table_name =~ s{_+}{_}sgio;
	$table_name =~ s{auto_increment}{autoinc}siog;
	$table_name =~ s{partition_by}{part_by}siog;
	$table_name =~ s{partition}{part}siog;
	$table_name =~ s{partitions}{parts}siog;
	$table_name =~ s{values_less_than}{}siog;
	$table_name =~ s{integer}{int}siog;

	$table->[TABLE_NAME] = $table_name;

	$table_copy[TABLE_ENGINE] = "ENGINE=".$table_copy[TABLE_ENGINE] if $table_copy[TABLE_ENGINE] ne '';
	$table_copy[TABLE_ROW_FORMAT] = "ROW_FORMAT=".$table_copy[TABLE_ROW_FORMAT] if $table_copy[TABLE_ROW_FORMAT] ne '';
	$table_copy[TABLE_CHARSET] = "CHARACTER SET ".$table_copy[TABLE_CHARSET] if $table_copy[TABLE_CHARSET] ne '';
	$table_copy[TABLE_COLLATION] = "COLLATE ".$table_copy[TABLE_COLLATION] if $table_copy[TABLE_COLLATION] ne '';
	$table_copy[TABLE_PARTITION] = "PARTITION BY ".$table_copy[TABLE_PARTITION] if $table_copy[TABLE_PARTITION] ne '';

	delete $table_copy[TABLE_ROW];	# Do not include number of rows in the CREATE TABLE
	delete $table_copy[TABLE_PK];	# Do not include PK definition at the end of CREATE TABLE

	$table->[TABLE_SQL] = join(' ' , grep { $_ ne '' } @table_copy);
}	

foreach my $table_id (0..$#tables) {
	my $table = $tables[$table_id];
	my @table_copy = @$table;
	my @fields_copy = @fields;
	
	if (lc($table->[TABLE_ENGINE]) eq 'falcon') {
		@fields_copy =  grep {
			!($_->[FIELD_TYPE] =~ m{blob|text}io && $_->[FIELD_INDEX] ne '')
		} @fields ;
	}

	say("# Creating table $table_copy[TABLE_NAME] .");

	if ($table_copy[TABLE_PK] ne '') {
		my $pk_field;
		$pk_field->[FIELD_NAME] = 'pk';
		$pk_field->[FIELD_TYPE] = $table_copy[TABLE_PK];
		$pk_field->[FIELD_INDEX] = 'primary key';
		$pk_field->[FIELD_INDEX_SQL] = 'primary key (pk)';
		$pk_field->[FIELD_SQL] = 'pk '.$table_copy[TABLE_PK];
		push @fields_copy, $pk_field;
	}

	# Make field ordering in every table different.
	# This exposes bugs caused by different physical field placement
	
	$prng->shuffleArray(\@fields_copy);
	
	output ("DROP TABLE IF EXISTS $table->[TABLE_NAME]");

	# Compose the CREATE TABLE statement by joining all fields and indexes and appending the table options

	my @field_sqls = join(",\n", map { $_->[FIELD_SQL] } @fields_copy);

	my @index_fields = grep { $_->[FIELD_INDEX_SQL] ne '' } @fields_copy;

	my $index_sqls = $#index_fields > -1 ? join(",\n", map { $_->[FIELD_INDEX_SQL] } @index_fields) : undef;

	my $create_result = output ("CREATE TABLE `$table->[TABLE_NAME]` (".join(",\n\t", grep { defined $_ } (@field_sqls, $index_sqls) ).") $table->[TABLE_SQL] ");
	if ($create_result > 1) {
		say("# Unable to create table $table->[TABLE_NAME], skipping...");
		next;
	}

	if ($table->[TABLE_ROW] > 1000) {
		output("SET AUTOCOMMIT=OFF");
		output("START TRANSACTION");
	}

	my @row_buffer;
	foreach my $row_id (1..$table->[TABLE_ROW]) {
		my @data;
		foreach my $field (@fields_copy) {
			my $value;

			if ($field->[FIELD_INDEX] eq 'primary key') {
				if ($field->[FIELD_TYPE] =~ m{auto_increment}sio) {
					$value = undef;		# Trigger auto-increment by inserting NULLS for PK
				} else {	
					$value = $row_id;	# Otherwise, insert sequential numbers
				}
			} else {
				my (@possible_values, $value_type);

				if ($field->[FIELD_TYPE] =~ m{date|time|year}sio) {
					$value_type = DATA_TEMPORAL;
				} elsif ($field->[FIELD_TYPE] =~ m{blob|text}sio) {
					$value_type = DATA_BLOB;
				} elsif ($field->[FIELD_TYPE] =~ m{int|float|double|dec|numeric|fixed|bool|bit}sio) {
					$value_type = DATA_NUMBER;
				} else {
					$value_type = DATA_STRING;
				}

				if ($field->[FIELD_NULLABILITY] eq 'not null') {
					# Remove NULL from the list of allowed values
					@possible_values = grep { lc($_) ne 'null' } @{$data_perms[$value_type]};
				} else {
					@possible_values = @{$data_perms[$value_type]};
				}

				die("# Unable to generate data for field '$field->[FIELD_TYPE] $field->[FIELD_NULLABILITY]'") if $#possible_values == -1;
		
				my $possible_value = $prng->arrayElement(\@possible_values);
				$possible_value = $field->[FIELD_TYPE] if not defined $possible_value;

				if ($prng->isFieldType($possible_value)) {
					$value = $prng->fieldType($possible_value);
				} else {
					$value = $possible_value;		# A simple string literal as specified
				}
			}

			# Blob values are generated as LOAD_FILE , so do not quote them.
			if ($value =~ m{load_file}sio) {
				push @data, defined $value ? $value : "NULL";
			} else {
				$value =~ s{'}{\\'}sgio;
				push @data, defined $value ? "'$value'" : "NULL";
			}	
		}

		push @row_buffer, " (".join(', ', @data).") ";

		if (
			(($row_id % 10) == 0) ||
			($row_id == $table->[TABLE_ROW])
		) {
			output("INSERT IGNORE INTO $table->[TABLE_NAME] VALUES ".join(', ', @row_buffer));
			@row_buffer = ();
		}

		if (($row_id % 10000) == 0) {
			output("COMMIT");
			say("# Progress: loaded $row_id out of $table->[TABLE_ROW] rows");
		}
	}
	output("COMMIT");
}

output("COMMIT");


sub output {
	my $statement = shift;
	if (defined $dbh) {
		$dbh->do($statement);
		return $dbh->err();
	} else {
		print "$statement;\n";
		return undef;
	}
}

sub help {

        print <<EOF

        $0 - Random Data Generator. Options:

        --dsn           : MySQL DBI resource to connect to (default: no DSN, print CREATE/INSERT statements to STDOUT)
        --engine        : Table engine to use when creating tables with gendata (default: no ENGINE for CREATE TABLE)
        --config        : Configuration ZZ file describing the data (see RandomDataGenerator in MySQL Wiki)
	--rows		: Number of rows to generate for each table, unless specified in the ZZ file
        --help          : This help message
EOF
        ;
        exit(1);
}
