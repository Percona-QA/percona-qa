# Copyright (c) 2008, 2011, Oracle and/or its affiliates. All rights reserved.
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

package GenTest::Validator::ExecutionTimeComparator;

################################################################################
#
# This validator compares the execution times of queries against two different 
# servers. It may repeat each suitable query and compute averages if configured
# to do so (see below).
#
# If the ratio between the execution times of the two servers is above or below
# a given threshold, the query is written to the test's output as well as a
# CSV text file (optional) at the end of the test run.
#
# The validator may be configured by editing this file (adjusting the values
# of certain variables and constants). Configurable properties include:
#   - minimum ratio for which we want to report queries
#   - minumum execution time to care about
#   - whether or not to compare EXPLAIN output
#   - whether or not to repeat queries N times and compute average execution times.
#   - whether or not to repeat given queries against multiple tables.
#   - whether or not to write results to a file, and this file's name.
#
# Requires the use of two basedirs.
#
################################################################################

require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Comparator;
use GenTest::Result;
use GenTest::Validator;
use Data::Dumper;


# Configurable constants:
use constant MIN_DURATION   => 0.2; # (seconds) Queries with lower execution times are skipped.
use constant MIN_RATIO      => 5;   # Minimum speed-up or slow-down required in order to report a query
use constant MAX_ROWS       => 20;  # Skip query if initial execution resulted in more than so many rows.
use constant QUERY_REPEATS  => 0;   # Repeat each incoming query this many times and compute averge numbers.

# NOTE: If QUERY_REPEATS is > 0, execution times for the original execution
# will be ignored when computing averages and doing time comparisons. 
# If QUERY_REPEATS == 0, numbers from the first execution will be used.


# CSV file with result data. Set variable to undef if you want to disable this.
my $outfile = "rqg_executiontimecomp.txt";

# Tables against which to re-run the query and repeat validation.
# See BEGIN block for contents and further details.
my @tables;

my $skip_explain = 0;   # set to 0 to do EXPLAIN comparisons, or 1 to skip.


# Result variables, counters
my @execution_times;
my %execution_ratios;
my $total_queries = 0;      # Number of comparable queries
my $candidate_queries = 0;  # Number of original queries with results entering this validator
my $different_plans = 0;    # Number of queries with different query plan from EXPLAIN
my $zero_queries = 0;       # Number of queries with execution time of zero
my $quick_queries = 0;      # Number of queries with execution times lower than MIN_DURATION for both servers
my $over_max_rows = 0;      # Number of queries that produce more than MAX_ROWS rows
my $non_status_ok = 0;      # Number of failed queries (status != STATUS_OK)
my $non_selects = 0;        # Number of non-SELECT statements
my $no_results = 0;         # Number of (rejected) queries with no results (original query/tables only)

# If a query modified by this validator fails, a non-ok status may be returned 
# from the validator even if the original query executed OK.
# Still, if a table variation query does not pass the various threshold checks,
# the total status is not returned until all table variations are done.
# This allows one to specify a small table in the grammar and repeat queries
# against increasingly larger tables.
# Regular repetitions against the same table will stop if the first
# execution did not pass the various checks.
my $total_status = STATUS_OK;


sub BEGIN {
    # @tables: Tables against which we should repeat the original query and 
    # re-validate.
    # Example: Configure the grammar to produce queries only against a single 
    #          table. Do systematic testing of different tables by setting e.g.:
    #
    #   @tables = ('AA', 'B', 'BB', 'C', 'CC', 'D', 'DD', 'E');
    @tables = ();

    say('ExecutionTimeComparator will repeat suitable queries against '.
        scalar(@tables)." tables: @tables") if scalar(@tables) > 0;
    say('ExecutionTimeComparator will repeat suitable queries '.QUERY_REPEATS.
        ' times and calculate average execution times.') if QUERY_REPEATS > 0;
}


sub validate {
    # For each original query entering this validator, do this...

    my ($comparator, $executors, $results) = @_;

    if ($#$results != 1) {
        $no_results++;
        return STATUS_WONT_HANDLE;
    }

    my $query = $results->[0]->query();
    $candidate_queries++;

    if ($query !~ m{^\s*SELECT}sio) {
        $non_selects++;
        return STATUS_WONT_HANDLE;
    }
    if ($results->[0]->status() != STATUS_OK || $results->[1]->status() != STATUS_OK) {
        $non_status_ok++;
        return STATUS_WONT_HANDLE
    }

    # First check the original query.
    # This will also repeat the query if the constant QUERY_REPEATS is > 0.
    my $compare_status = compareDurations($executors, $results, $query);
    $total_status = $compare_status if $compare_status > $total_status;


    # In the case of @tables being defined, we try to repeat each query against
    # the specified tables. We skip this if we cannot recognize the original
    # table name.
    if (defined @tables) {
        my $tableVarStatus = doTableVariation($executors, $results, $query, $total_status);
        $total_status = $tableVarStatus if $tableVarStatus > $total_status;
    }


    return $total_status;
}


sub compareDurations {
    # $results is from the original query execution (outside this validator),
    # or undefined if this is a query that is a variation of the original.
    my ($executors, $results, $query) = @_;

    # In case of table variation we do not have any results for the new 
    # query, so we need to execute it once, for EXPLAIN comparison etc.
    if ($results == undef) {
        $results->[0] = $executors->[0]->execute($query);
        $results->[1] = $executors->[1]->execute($query);
    }

    my $time0 = $results->[0]->duration();
    my $time1 = $results->[1]->duration();

    # We only do EXPLAIN checking for the first execution, not repetitions.
    if ($skip_explain == 0) {
        my @explains;
        foreach my $executor_id (0..1) {
            my $explain_extended = $executors->[$executor_id]->dbh()->selectall_arrayref("EXPLAIN EXTENDED $query");
            my $explain_warnings = $executors->[$executor_id]->dbh()->selectall_arrayref("SHOW WARNINGS");
            $explains[$executor_id] = Dumper($explain_extended)."\n".Dumper($explain_warnings);
        }

        $different_plans++ if $explains[0] ne $explains[1];
    }

    if ($time0 == 0 || $time1 == 0) {
        $zero_queries++;
        return STATUS_WONT_HANDLE;
    }

    if ($results->[0]->rows() > MAX_ROWS) {
        $over_max_rows++;
        return STATUS_WONT_HANDLE;
    }

    # Repeat the same query, collect results (depending on settings).
    my $sum_time0 = 0;
    my $sum_time1 = 0;
    my $count_time0 = 0;
    my $count_time1 = 0;
    my $repeats_left = QUERY_REPEATS;
    while ($repeats_left > 0) {
        $sum_time0 += $executors->[0]->execute($query)->duration();
        $count_time0++;
        $sum_time1 += $executors->[1]->execute($query)->duration();
        $count_time1++;
        $repeats_left--;
    }

    # Compute averages if QUERY_REPEAT is set.
    # We ignore the results from the first query execution (before entering 
    # the validator), as it may be off for some reason.
    # We use only the first 4 decimals.
    if (QUERY_REPEATS > 0) {
        $time0 = sprintf('%.4f', ($sum_time0 / $count_time0));
        $time1 = sprintf('%.4f', ($sum_time1 / $count_time1));
    }

    if ($time0 < MIN_DURATION && $time1 < MIN_DURATION) {
            $quick_queries++;
            return STATUS_WONT_HANDLE;
    }

    # We prepare a file for output of per-query performance numbers.
    # Only do this if the file is not already open.
    if (defined $outfile && (tell OUTFILE == -1) ) {
        open (OUTFILE, ">$outfile");
        print(OUTFILE "# Numbers from the RQG's ExecutionTimeComparator validator.\n\n");
        print(OUTFILE "ratio\treversed_ratio\ttime0\ttime1\tquery\n");
    }

    my $ratio = $time0 / $time1;
    $ratio = sprintf('%.4f', $ratio) if $ratio > 0.0001;

    # Print both queries that became faster and those that became slower
    if ( ($ratio >= MIN_RATIO) || ($ratio <= (1/MIN_RATIO)) ) {
        say("ratio = $ratio; time0 = $time0 sec; time1 = $time1 sec; query: $query");
        # also print to output file
        my $reversed_ratio = sprintf('%.4f', ($time1/$time0));
        print(OUTFILE "$ratio\t$reversed_ratio\t$time0\t$time1\t$query\n") if defined $outfile;

        #else:
        #  Ratio is too low, don't report the query.
        #  say("DEBUG: ratio = $ratio; time0 = $time0 sec; time1 = $time1 sec; query: $query");
    }

    $total_queries++;
    $execution_times[0]->{sprintf('%.1f', $time0)}++;
    $execution_times[1]->{sprintf('%.1f', $time1)}++;

    push @{$execution_ratios{sprintf('%.1f', $ratio)}}, $query;

    return STATUS_OK;

}


sub doTableVariation() {
    my ($executors, $results, $query, $status) = @_;
    
    # The goal is to repeat the same query against different tables.
    # We assume the query is simple, with a single "FROM <letter(s)>" construct.
    # Otherwise, skip the repeating (this detection may be improved).

    my $lookfor_pattern = "FROM ([a-zA-Z]+) ";

    # Find the original table name to avoid repeating it unnecessarily.
    my $orig_table;
    if ($query =~ m{$lookfor_pattern}) {
        $orig_table = $1;
    } else {
        # Query structure not recognized, unable to find original table name.
        # Skip further processing of this query.
        return $status;
    }

    # Construct new queries based on the original, replacing the table name.
    foreach my $table ( @tables ) {
        if ($table eq $orig_table) {
            # do not repeat the original
            next;
        }
        my $new_query = $query;
        $new_query =~ s/$lookfor_pattern/FROM $table /; # change table name

        # We pass undef as "results" parameter so that the new query will be
        # executed at least once.
        my $compare_status = compareDurations($executors, undef, $new_query);

        # One table variation query may yield STATUS_WONT_HANDLE, while others
        # may yield STATUS_OK. We return the status from the last variation and
        # ignore the others, assuming previous checks have taken care of 
        # unwanted queries and errors.

        $status = $compare_status;
    }

    return $status;
}


sub DESTROY {
    say("Total number of queries entering ExecutionTimeComparator: $candidate_queries");
    say("Excluded non-SELECT queries: ".$non_selects);
    say("Extra tables used for query repetition: ".scalar(@tables));
    say("Query repetitions per table per query: ".QUERY_REPEATS);
    say("Queries with execution time of 0: ".$zero_queries);
    say("Queries with execution time lower than MIN_DURATION (".MIN_DURATION." s): ".$quick_queries);
    say("Queries that were skipped due to returning more than MAX_ROWS (".MAX_ROWS.") rows: ".$over_max_rows);
    say("Queries that were skipped due to missing results: ".$no_results);
    say("Queries that were skipped due to not returning STATUS_OK: ".$non_status_ok);
    say("Queries with different EXPLAIN plans: $different_plans") if ($skip_explain == 0);
    say("Queries suitable for execution time comparison: $total_queries");
    say("Notable execution times for basedir0 and basedir1, respectively:"); 
    print Dumper \@execution_times;
    foreach my $ratio (sort keys %execution_ratios) {
        print "ratio = $ratio; queries = ".scalar(@{$execution_ratios{$ratio}}).":\n";
        if (
            ($ratio <= (1 - (1 / MIN_RATIO) ) ) ||
            ($ratio >= MIN_RATIO)
        ) {
            foreach my $query (@{$execution_ratios{$ratio}}) {
                print "$query\n";
            }
        }
    }
    if (defined $outfile && -e $outfile) {
        close(OUTFILE);
        say("See file $outfile for results from ExecutionTimeComparator");
    }
}

1;
