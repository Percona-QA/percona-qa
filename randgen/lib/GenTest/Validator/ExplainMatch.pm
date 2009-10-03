package GenTest::Validator::ExplainMatch;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Simplifier::Test;
use Data::Dumper;

my $match_string = 'unique row not found';

1;

sub validate {
        my ($validator, $executors, $results) = @_;

	my $executor = $executors->[0];
	my $query = $results->[0]->query();

	return STATUS_WONT_HANDLE if $query !~ m{^\s*SELECT}sio;

        my $explain_output = $executor->dbh()->selectall_arrayref("EXPLAIN $query");

	my $explain_string = Dumper $explain_output;

	if ($explain_string =~ m{$match_string}sio) {
		say("EXPLAIN $query matches $match_string");
		my $simplifier_test = GenTest::Simplifier::Test->new(
		        executors => [ $executor ],
		        queries => [ $query , "EXPLAIN $query" ]
		);
		my $simplified_test = $simplifier_test->simplify();
		say("Simplified test:");
		print $simplified_test;
		return STATUS_CUSTOM_OUTCOME;
	} else {
		return STATUS_OK;
	}
}

1;
