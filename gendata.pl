#!/usr/bin/perl

$| = 1;
use strict;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use GenTest;
use GenTest::Constants;
use GenTest::App::Gendata;
use Getopt::Long;

my ($config_file, $debug, $engine, $help, $dsn, $rows, $varchar_len,
    $views, $server_id, $seed);

my $opt_result = GetOptions(
	'help'	=> \$help,
	'config:s' => \$config_file,
	'debug'	=> \$debug,
	'dsn:s'	=> \$dsn,
	'seed=s' => \$seed,
	'engine:s' => \$engine,
	'rows=i' => \$rows,
	'views' => \$views,
	'varchar-length=i' => \$varchar_len,
	'server-id=i' > \$server_id
);

help() if !$opt_result || $help || not defined $config_file;

exit(1) if !$opt_result;


my $app = GenTest::App::Gendata->new(config_file => $config_file,
                                     debug => $debug,
                                     dsn => $dsn,
                                     seed => $seed,
                                     engine => $engine,
                                     rows => $rows,
                                     views => $views,
                                     varchar_length => $varchar_len,
                                     server_id => $server_id);


my $status = $app->run();

exit $status;

sub help {

        print <<EOF
$0 - Random Data Generator. Options:

        --debug         : Turn on debugging for additional output
        --dsn           : DBI resource to connect to
        --engine        : Table engine to use when creating tables with gendata (default: no ENGINE for CREATE TABLE)
        --config        : Configuration ZZ file describing the data (see RandomDataGenerator in MySQL Wiki)
        --rows          : Number of rows to generate for each table, unless specified in the ZZ file
        --seed          : Seed to PRNG. if --seed=time the current time will be used. (default 1)
        --views         : Generate views
        --varchar-length: maximum length of strings (deault 1)
        --help          : This help message
EOF
        ;
        exit(1);
}
