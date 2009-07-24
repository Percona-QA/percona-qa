#!/usr/bin/perl

$| = 1;
use strict;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use DBI;
use Getopt::Long;
use GenTest;
use GenTest::Random;

my $prng = GenTest::Random->new( seed => 0 );

my $default_dsn = my $dsn = 'dbi:mysql:host=127.0.0.1:port=9306:user=root:database=test';
my ($engine, $help, $views);

my @ARGV_saved = @ARGV;

my $opt_result = GetOptions(
        'dsn=s' => \$dsn,
	'engine:s' => \$engine,
        'help' => \$help,
	'views' => \$views
);

help() if !$opt_result || $help;

say("Starting \n# $0 \\ \n# ".join(" \\ \n# ", @ARGV_saved));

my $dbh = DBI->connect($dsn);

help() if not defined $dbh;

my @names = ('A', 'B', 'C', 'D', 'E', 'AA', 'BB', 'CC', 'DD', 'AAA','BBB','CCC');
my @sizes = (0, 2, 20, 100, 1000, 0, 2, 20, 100, 0, 1, 20);
my $varchar_length = 1;
my $nullability = 'NOT NULL';

foreach my $i (0..$#names) {
	gen_table ($names[$i], $sizes[$i]);
}

$dbh->do("SET SQL_MODE= 'NO_ENGINE_SUBSTITUTION'");

sub gen_table {
	my ($name, $size) = @_;
	say("Creating table $name, size $size rows, engine $engine .");

	$dbh->do("DROP TABLE IF EXISTS $name");
	$dbh->do("
		CREATE TABLE $name (
			pk INTEGER AUTO_INCREMENT,
			int_nokey INTEGER $nullability,
			int_key INTEGER $nullability,

			date_key DATE $nullability,
			date_nokey DATE $nullability,

			time_key TIME $nullability,
			time_nokey TIME $nullability,

			datetime_key DATETIME $nullability,
			datetime_nokey DATETIME $nullability,

			varchar_key VARCHAR($varchar_length) $nullability,
			varchar_nokey VARCHAR($varchar_length) $nullability,

			PRIMARY KEY (pk),
			KEY (int_key),
			KEY (date_key),
			KEY (time_key),
			KEY (datetime_key),
			KEY (varchar_key)
		) ".(length($name) == 2 ? " AUTO_INCREMENT=".(length($name) * 5) : "").($engine ne '' ? " ENGINE=$engine" : "")
		# For tables named like CC and CCC, start auto_increment with some offset. This provides better test coverage since
		# joining such tables on PK does not produce only 1-to-1 matches.
	);
	
	if (defined $views) {
		$dbh->do('CREATE VIEW view_'.$name.' AS SELECT * FROM '.$name);
	}

	foreach my $row (1..$size) {
	
		# Pick null in 20% of the cases

		my $rnd_int1 = $prng->uint16(0,4) == 4 ? undef : $prng->digit();
		my $rnd_int2 = $prng->uint16(0,4) == 4 ? undef : $prng->digit();

		# Pick null in 20% of the cases and '0000-00-00' in another 20%, pick real date/time/datetime for the rest

		my $rnd_date = $prng->date();

		$rnd_date = ($rnd_date, $rnd_date, $rnd_date, undef, '0000-00-00')[$prng->uint16(0,4)];
		my $rnd_time = $prng->time();
		$rnd_time = ($rnd_time, $rnd_time, $rnd_time, undef, '00:00:00')[$prng->uint16(0,4)];

		my $rnd_datetime = $prng->datetime();
		my $rnd_datetime_date_only = $prng->date();
		$rnd_datetime = ($rnd_datetime, $rnd_datetime, $rnd_datetime_date_only." 00:00:00", undef, '0000-00-00 00:00:00')[$prng->uint16(0,4)];

		my $rnd_varchar = $prng->uint16(0,4) == 4 ? undef : $prng->string($varchar_length);

		$dbh->do("
			INSERT IGNORE INTO $name (
				int_key, int_nokey,
				date_key, date_nokey,
				time_key, time_nokey,
				datetime_key, datetime_nokey,
				varchar_key, varchar_nokey
			) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		", undef,
			$rnd_int1, $rnd_int2,
			$rnd_date, $rnd_date,
			$rnd_time, $rnd_time,
			$rnd_datetime, $rnd_datetime,
			$rnd_varchar, $rnd_varchar
		);
	}
}

sub help {
print <<EOF

	$0 - Sample table generator. Options:

	--dsn		: MySQL DBI resource to connect to (default $default_dsn)
	--engine	: Table engine to use when creating tables (default: no ENGINE in CREATE TABLE )
	--help		: This help message 
EOF
;
	safe_exit(1);
}

