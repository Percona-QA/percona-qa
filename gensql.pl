#!/usr/bin/perl
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Generator::FromGrammar;
use GenTest::Executor::MySQL;

use Getopt::Long;

$| = 1;

my ($gendata, $help, $grammar_file, $mask, $mask_level, $dsn);
my $queries = my $default_queries = 1000;
my $seed = 1;

my @ARGV_saved = @ARGV;

my $opt_result = GetOptions(
	'grammar=s' => \$grammar_file,
	'queries=i' => \$queries,
	'help' => \$help,
	'seed=s' => \$seed,
	'mask=i' => \$mask,
	'mask-level=i' => \$mask_level,
	'dsn=s' => \$dsn
);

help() if !$opt_result || $help || not defined $grammar_file;

my $generator = GenTest::Generator::FromGrammar->new(
	grammar_file => $grammar_file,
	seed => ($seed eq 'time') ? time() : $seed,
	mask => $mask,
        mask_level => $mask_level
);

return STATUS_ENVIRONMENT_FAILURE if not defined $generator;

my $executor;

if (defined $dsn) {
	$executor = GenTest::Executor::MySQL->new(
		dsn => $dsn
	);
	exit (STATUS_ENVIRONMENT_FAILURE) if not defined $executor;
}

if (defined $executor) {
	my $init_result = $executor->init();
	exit ($init_result) if $init_result > STATUS_OK;
}

foreach my $i (1..$queries) {
	my $queries = $generator->next([$executor]);
	if (
		(not defined $queries) ||
		($queries->[0] eq '')
	) {
		say("Grammar produced an empty query. Terminating.");
		exit(STATUS_ENVIRONMENT_FAILURE);
	}
	my $sql = join('; ',@$queries);
	print $sql.";\n";
}

exit(0);

sub help {
        print <<EOF

        $0 - Generate random queries from an SQL grammar and pipe them to STDOUT

        --grammar       : Grammar file to use for generating the queries (REQUIRED);
	--seed		: Seed for the pseudo-random generator
        --queries       : Numer of queries to generate (default $default_queries);
	--dsn		: The DSN of the database that will be used to resolve rules such as _table , _field
        --help          : This help message
EOF
        ;
	exit(1);
}

