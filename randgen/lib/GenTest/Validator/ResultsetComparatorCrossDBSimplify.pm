# Copyright (c) 2008, 2011 Oracle and/or its affiliates. All rights reserved.
# Copyright (c) 2013, Monty Program Ab.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

# Fork of ResultsetComparatorSimplify for a 2-way comparison where the two
# executors are DIFFERENT database providers/dialects (e.g. Percona Server vs
# MariaDB), typically driven by a grammar using /*executor1 ... */
# /*executor2 ... */ tags so each server sees its own native SQL. By the time
# validate() runs, $results->[N]->query() is already resolved to executor N's
# own dialect and is not necessarily valid SQL on the other executor.
#
# ResultsetComparatorSimplify's oracle re-sends executor 0's resolved query
# text to every executor in a loop -- correct only when both executors share
# one SQL dialect. On a genuinely different-dialect pair, that first re-send
# fails with an execution error on the other server, so its simplify() aborts
# immediately with "failed to reproduce the same issue" without ever
# attempting a single reduction. See ResultsetComparatorSimplify.pm, which is
# left unmodified for its original same-dialect use case.
#
# This validator instead simplifies each executor's own query against its own
# baseline result, never sending one server's SQL to another. That is
# logically equivalent for confirming the original mismatch: if executor 0's
# simplified query still reproduces executor 0's original result, and
# executor 1's simplified query still reproduces executor 1's original
# result, and those two original results already disagreed (that's why we're
# in this branch at all), the two simplified results necessarily still
# disagree too.
#
# One tradeoff versus the original: because each side is only required to
# match its own baseline (not to keep disagreeing with the other side), this
# can be less aggressive than ResultsetComparatorSimplify's single-oracle
# approach on a same-dialect pair -- a candidate reduction that changes
# executor 0's own result but coincidentally keeps it still-different from
# executor 1 would have been accepted there, but is rejected here by this
# stricter, self-consistency-only criterion. That tradeoff is the reason this
# lives as a separate validator rather than a change to the original.
#
# Known remaining limitation, not addressed here: DBIx::MyParsePP (the SQL
# parser GenTest::Simplifier::SQL uses to build a prunable tree) predates
# window functions and CTEs, so it cannot parse `RANK() OVER (...)` or
# `WITH ... AS (...)` at all. A mismatch on such a query will still fail to
# simplify ("Unable to parse query" / "Could not simplify failure, appears to
# be sporadic"), same as with ResultsetComparatorSimplify.

package GenTest::Validator::ResultsetComparatorCrossDBSimplify;

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

sub validate {
	my ($comparator, $executors, $results) = @_;

	return STATUS_WONT_HANDLE if $#$results != 1;

	return STATUS_WONT_HANDLE if $results->[0]->query() =~ m{EXPLAIN}sio;

	if ( $results->[0]->err() != $results->[1]->err() ) {
		say("Query: ".$results->[0]->query()."; failed: error code mismatch between servers ('".$results->[0]->errstr()."' vs. '".$results->[1]->errstr()."')");
		return STATUS_ERROR_MISMATCH;
	}

	return STATUS_WONT_HANDLE if $results->[0]->status() != STATUS_OK;
	return STATUS_WONT_HANDLE if $results->[1]->status() != STATUS_OK;

	return STATUS_WONT_HANDLE if defined $results->[0]->warnings();
	return STATUS_WONT_HANDLE if defined $results->[1]->warnings();

	my $query = $results->[0]->query();
	my $compare_outcome = GenTest::Comparator::compare($results->[0], $results->[1]);

	if ( ($compare_outcome == STATUS_LENGTH_MISMATCH) ||
	     ($compare_outcome == STATUS_CONTENT_MISMATCH)
	) {
		say("---------- RESULT COMPARISON ISSUE START ----------");
	}

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
		my @baseline_results = @$results;
		my @simplified_queries;

		for my $i (0 .. $#$executors) {
			my $executor       = $executors->[$i];
			my $executor_query = $results->[$i]->query();
			next if $executor_query =~ m{^\s*$}sio;

			my $simplifier_sql = GenTest::Simplifier::SQL->new(
				oracle => sub {
					my $oracle_query = shift;
					my $oracle_result = $executor->execute($oracle_query, 1);

					return ORACLE_ISSUE_STATUS_UNKNOWN if $oracle_result->status() != STATUS_OK;
					return ORACLE_ISSUE_STATUS_UNKNOWN if defined $oracle_result->warnings();

					#
					# If both the candidate and the baseline are empty, we can
					# not decide if the issue continues to be repeatable or
					# not. So, to be safe, we return "unknown", otherwise we
					# risk messing up the differential coverage reports
					#
					if (($oracle_result->rows() == 0) && ($baseline_results[$i]->rows() == 0)) {
						return ORACLE_ISSUE_STATUS_UNKNOWN;
					}

					my $self_compare = GenTest::Comparator::compare($oracle_result, $baseline_results[$i]);

					if ($self_compare == STATUS_OK) {
						return ORACLE_ISSUE_STILL_REPEATABLE;
					} else {
						return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
					}
			        }
			);

			$simplified_queries[$i] = $simplifier_sql->simplify($executor_query);
		}

		if ((defined $simplified_queries[0]) && (defined $simplified_queries[1])) {
			say("Simplified query (executor 0): $simplified_queries[0];");
			say("Simplified query (executor 1): $simplified_queries[1];");

			my @explains = (
				$executors->[0]->execute("EXPLAIN ".$simplified_queries[0]),
				$executors->[1]->execute("EXPLAIN ".$simplified_queries[1])
			);
	                say("EXPLAIN diff:");
			say(GenTest::Comparator::dumpDiff(@explains));

			my $simplified_results = [];
			$simplified_results->[0] = $executors->[0]->execute($simplified_queries[0], 1);
			$simplified_results->[1] = $executors->[1]->execute($simplified_queries[1], 1);
			say("Result set diff:");
			say(GenTest::Comparator::dumpDiff($simplified_results->[0], $simplified_results->[1]));

			my $simplifier_test = GenTest::Simplifier::Test->new(
				executors	=> $executors,
				results		=> [ $simplified_results , $results ]
			);
			# show_index is enabled for result difference queries its good to see the index details,
			# the value 1 is used to define if show_index is enabled, to disable dont assign a value.
			my $show_index = 1;
			my $simplified_test = $simplifier_test->simplify($show_index);

			my $tmpfile = tmpdir().abs($$).time().".test";
			# NOTE: GenTest::Simplifier::Test's .test format embeds one shared
			# query text; it has no notion of per-executor dialect tags, so it
			# renders executor 0's minimized query only. Executor 1's
			# minimized query is the "Simplified query (executor 1): ..." line
			# logged above -- consult both when the two dialects diverge.
			say("Dumping .test to $tmpfile (executor 0 query only; see log above for executor 1's minimized query)");
			open (TESTFILE, '>'.$tmpfile);
			print TESTFILE $simplified_test;
			close TESTFILE;
		} else {
			say("Could not simplify failure, appears to be sporadic.");
		}
	}

	if ( ($compare_outcome == STATUS_LENGTH_MISMATCH) ||
	     ($compare_outcome == STATUS_CONTENT_MISMATCH)
	) {
		say("---------- RESULT COMPARISON ISSUE END ------------");
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
