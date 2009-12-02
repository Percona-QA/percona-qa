#!/usr/bin/perl
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Properties;
use GenTest::Generator::FromGrammar;
use GenTest::Executor;
use Getopt::Long;

my $DEFAULT_QUERIES = 1000;

my @ARGV_saved = @ARGV;
my $options = {};
my $opt_result = GetOptions($options,
			    'config=s',
			    'grammar=s',
			    'queries=i',
			    'help',
			    'seed=s',
			    'mask=i',
			    'mask-level=i',
			    'dsn=s');

help() if !$opt_result;

my $config = GenTest::Properties->new(options => $options,
				      defaults => {seed => 1, 
						   queries=> $DEFAULT_QUERIES},
				      legal => ['config',
						'queries',
						'help',
						'seed',
						'mask',
						'mask-level',
						'dsn'],
				      required => ['grammar'],
				      help => \&help);

my $generator = GenTest::Generator::FromGrammar->new(
    grammar_file => $config->grammar,
    seed => ($config->seed eq 'time') ? time() : $config->seed,
    mask => $config->mask,
    mask_level => $config->property('mask-level')
    );

return STATUS_ENVIRONMENT_FAILURE if not defined $generator;

my $executor;

if (defined $config->dsn) {
    $executor = GenTest::Executor->newFromDSN($config->dsn);
    exit (STATUS_ENVIRONMENT_FAILURE) if not defined $executor;
}

if (defined $executor) {
    my $init_result = $executor->init();
    exit ($init_result) if $init_result > STATUS_OK;
}

foreach my $i (1..$config->queries) {
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

        --grammar   : Grammar file to use for generating the queries (REQUIRED);
        --seed      : Seed for the pseudo-random generator
        --queries   : Numer of queries to generate (default $DEFAULT_QUERIES);
        --dsn       : The DSN of the database that will be used to resolve rules such as _table , _field
        --mask      : A seed to a random mask used to mask (reeduce) the grammar.
        --mask-level: How many levels deep the mask is applied (default 1)
        --help      : This help message
EOF
        ;
    exit(1);
}

