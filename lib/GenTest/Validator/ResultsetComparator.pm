package GenTest::Validator::ResultsetComparator;

require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Comparator;
use GenTest::Result;
use GenTest::Validator;

sub validate {
	my ($comparator, $executors, $results) = @_;

	return STATUS_OK if $#$results != 1;

	my $query = $results->[0]->query();
	my $compare_outcome = GenTest::Comparator::compare($results->[0], $results->[1]);

	return STATUS_WONT_HANDLE if $results->[0]->status() == STATUS_SEMANTIC_ERROR || $results->[1]->status() == STATUS_SEMANTIC_ERROR;
	return STATUS_WONT_HANDLE if $results->[0]->query() =~ m{EXPLAIN}sio;

	if ($compare_outcome == STATUS_LENGTH_MISMATCH) {
		if ($query =~ m{^\s*select}io) {
	                say("Query: $query failed: result length mismatch between servers (".$results->[0]->rows()." vs. ".$results->[1]->rows().")");
			say(GenTest::Comparator::dumpDiff($results->[0], $results->[1]));
		} else {
	                say("Query: $query failed: affected_rows mismatch between servers (".$results->[0]->affectedRows()." vs. ".$results->[1]->affectedRows().")");
		}
	} elsif ($compare_outcome == STATUS_CONTENT_MISMATCH) {
		say("Query: ".$results->[0]->query()." failed: result content mismatch between servers.");
		say(GenTest::Comparator::dumpDiff($results->[0], $results->[1]));
	}

	#
	# If the discrepancy is found on SELECT, we reduce the severity of the error so that the test can continue
	# hopefully finding further errors in the same run or providing an indication as to how frequent the error is
	#
	# If the discrepancy is on an UPDATE, then the servers have diverged and the test can not continue safely.
	# 

	if ($query =~ m{^[\s/*!0-9]*(EXPLAIN|SELECT|ALTER|LOAD\s+INDEX|CACHE\s+INDEX)}io) {
		return $compare_outcome - STATUS_SELECT_REDUCTION;
	} else {
		return $compare_outcome;
	}
}

1;
