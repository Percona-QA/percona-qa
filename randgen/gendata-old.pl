#!/usr/bin/perl

$| = 1;
use strict;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use DBI;
use Getopt::Long;
use GenTest;
use GenTest::Constants;
use GenTest::App::GendataSimple;

my ($dsn, $engine, $help, $views);

my @ARGV_saved = @ARGV;

my $opt_result = GetOptions(
	'dsn=s' => \$dsn,
	'engine:s' => \$engine,
	'help' => \$help,
	'views' => \$views
);

my $default_dsn = GenTest::App::GendataSimple->defaultDsn();

help() if !$opt_result || $help;

my $app = GenTest::App::GendataSimple->new(dsn => $dsn,
                                           engine => $engine,
                                           views => $views);

say("Starting \n# $0 \\ \n# ".join(" \\ \n# ", @ARGV_saved));

my $status = $app->run();

if ($status > STATUS_OK) {
    exit $status;
} else {
    exit(0);
}



sub help {
print <<EOF
$0 - Simple data generator. Options:

    --dsn       : MySQL DBI resource to connect to (default $default_dsn)
    --engine    : Table engine to use when creating tables (default: no ENGINE in CREATE TABLE )
    --views     : Generate views
    --help      : This help message 
EOF
;
	safe_exit(1);
}

