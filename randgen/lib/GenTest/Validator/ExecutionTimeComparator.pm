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
my $total_queries;

use constant MINIMUM_TIME_INTERVAL	=> 1;	# seconds
use constant MINIMUM_RATIO		=> 2;	# Minimum speed-up or slow-down required in order to report a query

sub validate {
	my ($comparator, $executors, $results) = @_;

	return STATUS_WONT_HANDLE if $#$results != 1;

	my $time0 = $results->[0]->duration();
	my $time1 = $results->[1]->duration();
	my $query = $results->[0]->query();

	return STATUS_WONT_HANDLE if $time0 == 0 || $time1 == 0;
	return STATUS_WONT_HANDLE if $time0 < MINIMUM_TIME_INTERVAL && $time1 < MINIMUM_TIME_INTERVAL;

	my $ratio = $time0 / $time1;

	say("ratio = $ratio; time0 = $time0 sec; time1 = $time1 sec; query: $query") if $ratio >= MINIMUM_RATIO;

	$total_queries++;
	$execution_times[0]->{sprintf('%.1f', $time0)}++;
	$execution_times[1]->{sprintf('%.1f', $time1)}++;

	push @{$execution_ratios{sprintf('%.1f', $ratio)}}, $query;

	return STATUS_OK;
}

sub DESTROY {
	say("Total queries: $total_queries");
	print Dumper \@execution_times;
	foreach my $ratio (sort keys %execution_ratios) {
		print "ratio = $ratio; queries = ".scalar(@{$execution_ratios{$ratio}}).":\n";
		if (
			($ratio <= (1 - (1 / MINIMUM_RATIO) ) ) ||
			($ratio >= MINIMUM_RATIO)
		) {
			foreach my $query (@{$execution_ratios{$ratio}}) {
				print "$query\n";
			}
		}
	}
}

1;
