use strict;
use lib 'lib';
use lib '../lib';
use Carp;
use DBI;
use Getopt::Long;

use GenTest::Properties;
use GenTest::Constants;
use GenTest::Executor::MySQL;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;


my $options = {};
GetOptions($options,
           'config=s',
           'dsn=s@',
           'query=s');
my $config = GenTest::Properties->new(
    options => $options,
    defaults => {dsn=>['dbi:mysql:host=127.0.0.1:port=19306:user=root:database=test', 
                       'dbi:mysql:host=127.0.0.1:port=19308:user=root:database=test']},
    required => ['dsn','query']);


my @executors;
my @results;

foreach my $dsn (@{$config->dsn}) {
    print "....$dsn\n";
	my $executor = GenTest::Executor->newFromDSN($dsn);
	$executor->init();
	push @executors, $executor;

	my $result = $executor->execute($config->query, 1);
	push @results, $result;
}

my $simplifier_test = GenTest::Simplifier::Test->new(
	executors => \@executors,
	queries => [ $config->query ],
	results => [ \@results ]
);

my $test = $simplifier_test->simplify();

print $test;
