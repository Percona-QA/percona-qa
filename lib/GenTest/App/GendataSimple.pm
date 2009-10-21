package GenTest::App::GendataSimple;

@ISA = qw(GenTest);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Random;
use GenTest::Executor;

use Data::Dumper;

use constant GDS_DEFAULT_DSN => 'dbi:mysql:host=127.0.0.1:port=9306:user=root:database=test';

use constant GDS_DSN => 0;
use constant GDS_ENGINE => 1;
use constant GDS_VIEWS => 2;

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({
        'dsn' => GDS_DSN,
        'engine' => GDS_ENGINE,
        'views' => GDS_VIEWS},@_);

    if (not defined $self->[GDS_DSN]) {
        $self->[GDS_DSN] = GDS_DEFAULT_DSN;
    }
        
    return $self;
}

sub defaultDsn {
    return GDS_DEFAULT_DSN;
}

sub dsn {
    return $_[0]->[GDS_DSN];
}

sub engine {
    return $_[0]->[GDS_ENGINE];
}

sub views {
    return $_[0]->[GDS_VIEWS];
}

sub run {
    my ($self) = @_;

    my $prng = GenTest::Random->new( seed => 0 );

    my $executor = GenTest::Executor->newFromDSN($self->dsn());
    $executor->init();
    
    my @names = ('A', 'B', 'C', 'D', 'E', 'AA', 'BB', 'CC', 'DD');
    my @sizes = (0, 1, 20, 100, 1000, 0, 1, 20, 100);
    foreach my $i (0..$#names) {
        $self->gen_table ($executor, $names[$i], $sizes[$i], $prng);
    }
    
    # Need to create a dummy supdstituion for non-protable DUAL
    
    $executor->execute("DROP TABLE /*! IF EXISTS */ DUMMY");
    $executor->execute("CREATE TABLE DUMMY (I INTEGER)");
    $executor->execute("INSERT INTO DUMMY VALUES(0)");
    
    $executor->execute("SET SQL_MODE= 'NO_ENGINE_SUBSTITUTION'") if $executor->type == DB_MYSQL;
    return STATUS_OK;
}

sub gen_table {
	my ($self, $executor, $name, $size, $prng) = @_;

    my $varchar_length = 1;
    my $nullability = '/*! NULL */';  
    ### NULL is not a valid ANSI constraint, (but NOT NULL of course,
    ### is)

    my $engine = $self->engine();
    my $views = $self->views();

	if (
		($executor->type == DB_MYSQL) ||
		($executor->type == DB_DRIZZLE)
	) {

        say("Creating ".$executor->getName()." table $name, size $size rows, engine $engine .");
    
		### This variant is needed due to
		### http://bugs.mysql.com/bug.php?id=47125

		$executor->execute("DROP TABLE /*! IF EXISTS */ $name");
		$executor->execute("
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
			KEY (varchar_key, int_key)
		) ".(length($name) > 1 ? " AUTO_INCREMENT=".(length($name) * 5) : "").($engine ne '' ? " ENGINE=$engine" : "")
						   # For tables named like CC and CCC, start auto_increment with some offset. This provides better test coverage since
						   # joining such tables on PK does not produce only 1-to-1 matches.
			);
		
    } elsif ($executor->type == DB_POSTGRES) {
        say("Creating ".$executor->getName()." table $name, size $size rows");
    
        my $increment_size = (length($name) > 1 ? (length($name) * 5) : 1);
		$executor->execute("DROP TABLE /*! IF EXISTS */ $name");
        $executor->execute("DROP SEQUENCE ".$name."_seq");
        $executor->execute("CREATE SEQUENCE ".$name."_seq INCREMENT 1 START $increment_size");
		$executor->execute("
		CREATE TABLE $name (
			pk INTEGER DEFAULT nextval('".$name."_seq') NOT NULL,
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

			PRIMARY KEY (pk))");

		$executor->execute("CREATE INDEX ".$name."_int_key ON $name(int_key)");
		$executor->execute("CREATE INDEX ".$name."_date_key ON $name(date_key)");
		$executor->execute("CREATE INDEX ".$name."_time_key ON $name(time_key)");
		$executor->execute("CREATE INDEX ".$name."_datetime_key ON $name(datetime_key)");
		$executor->execute("CREATE INDEX ".$name."_varchar_key ON $name(varchar_key, int_key)");

	} else {
        say("Creating ".$executor->getName()." table $name, size $size rows");

		$executor->execute("DROP TABLE /*! IF EXISTS */ $name");
		$executor->execute("
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

			PRIMARY KEY (pk)
		) ".(length($name) > 1 ? " AUTO_INCREMENT=".(length($name) * 5) : "").($engine ne '' ? " ENGINE=$engine" : "")
						   # For tables named like CC and CCC, start auto_increment with some offset. This provides better test coverage since
						   # joining such tables on PK does not produce only 1-to-1 matches.
			);
		
		$executor->execute("CREATE INDEX ".$name."_int_key ON $name(int_key)");
		$executor->execute("CREATE INDEX ".$name."_date_key ON $name(date_key)");
		$executor->execute("CREATE INDEX ".$name."_time_key ON $name(time_key)");
		$executor->execute("CREATE INDEX ".$name."_datetime_key ON $name(datetime_key)");
		$executor->execute("CREATE INDEX ".$name."_varchar_key ON $name(varchar_key, int_key)");
	};

	if (defined $views) {
		$executor->execute('CREATE VIEW view_'.$name.' AS SELECT * FROM '.$name);
	}

	my @values;

	foreach my $row (1..$size) {
	
		# 10% NULLs, 10% tinyint_unsigned, 80% digits

		my $pick1 = $prng->uint16(0,9);
		my $pick2 =	 $prng->uint16(0,9);
		my $rnd_int1 = $pick1 == 9 ? "NULL" : ($pick1 == 8 ? $prng->int(0,255) : $prng->digit() );
		my $rnd_int2 = $pick2 == 9 ? "NULL" : ($pick1 == 8 ? $prng->int(0,255) : $prng->digit() );

		# 10% NULLS, 10% '1900-01-01', pick real date/time/datetime for the rest

		my $rnd_date = "'".$prng->date()."'";

		$rnd_date = ($rnd_date, $rnd_date, $rnd_date, $rnd_date, $rnd_date, $rnd_date, $rnd_date, $rnd_date, "NULL", "'1900-01-01'")[$prng->uint16(0,9)];
		my $rnd_time = "'".$prng->time()."'";
		$rnd_time = ($rnd_time, $rnd_time, $rnd_time, $rnd_time, $rnd_time, $rnd_time, $rnd_time, $rnd_time, "NULL", "'00:00:00'")[$prng->uint16(0,9)];

		# 10% NULLS, 10% "1900-01-01 00:00:00', 20% date + " 00:00:00"

		my $rnd_datetime = $prng->datetime();
		my $rnd_datetime_date_only = $prng->date();
		$rnd_datetime = ($rnd_datetime, $rnd_datetime, $rnd_datetime, $rnd_datetime, $rnd_datetime, $rnd_datetime, $rnd_datetime_date_only." 00:00:00", $rnd_datetime_date_only." 00:00:00", "NULL", '1900-01-01 00:00:00')[$prng->uint16(0,9)];
		$rnd_datetime = "'".$rnd_datetime."'" if not $rnd_datetime eq "NULL";

		my $rnd_varchar = $prng->uint16(0,9) == 9 ? "NULL" : "'".$prng->string($varchar_length)."'";

		push(@values, "($rnd_int1, $rnd_int2, $rnd_date, $rnd_date, $rnd_time, $rnd_time, $rnd_datetime, $rnd_datetime, $rnd_varchar, $rnd_varchar)");

		## We do one insert per 500 rows for speed
		if ($row % 500 == 0 || $row == $size) {
			$executor->execute("
			INSERT /*! IGNORE */ INTO $name (
				int_key, int_nokey,
				date_key, date_nokey,
				time_key, time_nokey,
				datetime_key, datetime_nokey,
				varchar_key, varchar_nokey
			) VALUES " . join(",",@values));
			@values = ();
		}
	}
}

1;
