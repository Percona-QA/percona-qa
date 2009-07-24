package GenTest::Validator::ResultsetComparatorSimplify;

require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Comparator;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Executor::MySQL;
use GenTest::Simplifier::SQL;
use GenTest::Simplifier::Test;

use DBI;
use DBIx::MyParsePP;
use DBIx::MyParsePP::Rule;

my $empty_child = DBIx::MyParsePP::Rule->new();
my $myparse = DBIx::MyParsePP->new();
my $query_obj;
my %cache;

sub validate {
	my ($comparator, $executors, $results) = @_;

	return STATUS_WONT_HANDLE if $#$results != 1;
	return STATUS_WONT_HANDLE if $results->[0]->status() != STATUS_OK;
	return STATUS_WONT_HANDLE if $results->[1]->status() != STATUS_OK;

	%cache = ();

	my $query = $results->[0]->query();
	my $compare_outcome = GenTest::Comparator::compare($results->[0], $results->[1]);

	if ($compare_outcome == STATUS_LENGTH_MISMATCH) {
		if ($query =~ m{^\s*select}io) {
	                say("Query: $query; failed: result length mismatch between servers (".$results->[0]->rows()." vs. ".$results->[1]->rows().")");
			say(GenTest::Comparator::dumpDiff($results->[0], $results->[1]));
		} else {
	                say("Query: $query; failed: affected_rows mismatch between servers (".$results->[0]->affectedRows()." vs. ".$results->[1]->affectedRows().")");
		}
	} elsif ($compare_outcome == STATUS_CONTENT_MISMATCH) {
		say("Query: $query; failed: result content mismatch between servers.");
		say(GenTest::Comparator::dumpDiff($results->[0], $results->[1]));
	}

	if (
		($query =~ m{^\s*select}sio) && (
			($compare_outcome == STATUS_LENGTH_MISMATCH) ||
			($compare_outcome == STATUS_CONTENT_MISMATCH)
		)
	) {
		my $simplifier_sql = GenTest::Simplifier::SQL->new(
			oracle => sub {
				my $oracle_query = shift;
				my @oracle_results;
				foreach my $executor (@$executors) {
					push @oracle_results, $executor->execute($oracle_query, 1);

				}
				my $oracle_compare = GenTest::Comparator::compare($oracle_results[0], $oracle_results[1]);
				if (
					($oracle_compare == STATUS_LENGTH_MISMATCH) ||
					($oracle_compare == STATUS_CONTENT_MISMATCH)
				) {
					return 1;
				} else {
					return 0;
				}
		        }
		);

		my $simplified_query = $simplifier_sql->simplify($query);
		
		if (defined $simplified_query) {
			say("Simplified query: $simplified_query;");
			my $simplified_results = [];

			$simplified_results->[0] = $executors->[0]->execute($simplified_query);
			$simplified_results->[1] = $executors->[1]->execute($simplified_query);
			say(GenTest::Comparator::dumpDiff($simplified_results->[0], $simplified_results->[1]));

			my $simplifier_test = GenTest::Simplifier::Test->new(
				executors	=> $executors,
				results		=> [ $simplified_results , $results ]
			);

			my $simplified_test = $simplifier_test->simplify();

			my $tmpfile = tmpdir().$$.time().".test";
			say("Dumping .test to $tmpfile");
			open (TESTFILE, '>'.$tmpfile);
			print TESTFILE $simplified_test;
			close TESTFILE;
		} else {
			say("Could not simplify failure, appears to be sporadic.");
		}
	}

	#
	# If the discrepancy is found on SELECT, we reduce the severity of the error so that the test can continue
	# hopefully finding further errors in the same run or providing an indication as to how frequent the error is
	#
	# If the discrepancy is on an UPDATE, then the servers have diverged and the test can not continue safely.
	# 

	if ($query =~ m{^\s*(select|alter)}io) {
		return $compare_outcome - STATUS_SELECT_REDUCTION;
	} else {
		$compare_outcome;
	}
}

1;
