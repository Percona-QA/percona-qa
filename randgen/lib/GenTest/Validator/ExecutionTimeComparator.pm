# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
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

require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use GenTest;
use GenTest::Constants;
use GenTest::Comparator;
use GenTest::Result;
use GenTest::Validator;
use Data::Dumper;

my @execution_times;
my %execution_ratios;
my $total_queries = 0;
my $different_plans = 0;

use constant MIN_DURATION	=> 0.2;	# seconds
use constant MIN_RATIO		=> 5;	# Minimum speed-up or slow-down required in order to report a query
use constant MAX_ROWS		=> 20;

sub validate {
	my ($comparator, $executors, $results) = @_;

	return STATUS_WONT_HANDLE if $#$results != 1;

	my $time0 = $results->[0]->duration();
	my $time1 = $results->[1]->duration();
	my $query = $results->[0]->query();

	return STATUS_WONT_HANDLE if $query !~ m{^\s*SELECT}sio;
	return STATUS_WONT_HANDLE if $results->[0]->status() != STATUS_OK || $results->[0]->status() != STATUS_OK;

	my @explains;
	foreach my $executor_id (0..1) {
		my $explain_extended = $executors->[$executor_id]->dbh()->selectall_arrayref("EXPLAIN EXTENDED $query");
		my $explain_warnings = $executors->[$executor_id]->dbh()->selectall_arrayref("SHOW WARNINGS");
		$explains[$executor_id] = Dumper($explain_extended)."\n".Dumper($explain_warnings);
	}

	$different_plans++ if $explains[0] ne $explains[1];

	return STATUS_WONT_HANDLE if $time0 == 0 || $time1 == 0;
	return STATUS_WONT_HANDLE if $time0 < MIN_DURATION && $time1 < MIN_DURATION;
	return STATUS_WONT_HANDLE if $results->[0]->rows() > MAX_ROWS;

	my $ratio = $time0 / $time1;

	# Print both queries that became faster and those that became slower
	say("ratio = $ratio; time0 = $time0 sec; time1 = $time1 sec; query: $query") if ($ratio >= MIN_RATIO) || $ratio <= (1/MIN_RATIO);

	$total_queries++;
	$execution_times[0]->{sprintf('%.1f', $time0)}++;
	$execution_times[1]->{sprintf('%.1f', $time1)}++;

	push @{$execution_ratios{sprintf('%.1f', $ratio)}}, $query;

	return STATUS_OK;
}

sub DESTROY {
	say("Queries with different EXPLAIN plans: $different_plans; Queries suitable for execution time comparison: $total_queries.");
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
}

1;
