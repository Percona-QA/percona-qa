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

package GenTest::Transform::DisableChosenPlan;

require Exporter;
@ISA = qw(GenTest GenTest::Transform);

use strict;
use lib 'lib';
use GenTest;
use GenTest::Transform;
use GenTest::Constants;
use Data::Dumper;

#
# This Transform runs EXPLAIN on the query, determines which (subquery) optimizations were used
# and disables them so that the query can be rerun with a "second-best" plan. This way the best and
# the "second best" plans are checked against one another.
#
# This has the following benefits:
# 1. The query plan that is being validated is the one actually chosen by the optimizer, so that one can
# run a comprehensive subquery test without having to manually fiddle with @@optimizer_switch
# 2. The plan that is used for validation is hopefully also fast enough, as compared to using unindexed nested loop
# joins with re-execution of the enitre subquery for each loop.
#

my %explain2switch = (
	'firstmatch'		=> 'firstmatch',
	'cache'			=> 'subquery_cache',
	'materializ'		=> 'materialization',	# hypothetical
	'semijoin'		=> 'semijoin',
	'loosescan'		=> 'loosescan',
	'<exists>'		=> 'in_to_exists'
);

sub transform {
	my ($class, $original_query, $executor) = @_;

	return STATUS_WONT_HANDLE if $original_query !~ m{^\s*SELECT}sio;

	my $original_explain = $executor->execute("EXPLAIN EXTENDED $original_query");

	if ($original_explain->status() == STATUS_SERVER_CRASHED) {
		return STATUS_SERVER_CRASHED;
	} elsif ($original_explain->status() ne STATUS_OK) {
		return STATUS_ENVIRONMENT_FAILURE;
	}

	my $original_explain_string = Dumper($original_explain->data())."\n".Dumper($original_explain->warnings());

	my @transformed_queries;
	while (my ($explain_fragment, $optimizer_switch) = each %explain2switch) {
		if ($original_explain_string =~ m{$explain_fragment}si) {
			push @transformed_queries,
				"SET SESSION optimizer_switch='".$optimizer_switch."=OFF' ;",
				"$original_query /* TRANSFORM_OUTCOME_UNORDERED_MATCH */ ;",
				"SET SESSION optimizer_switch='".$optimizer_switch."=ON' ;"
			;
		}
	}
	if ($#transformed_queries > -1) {
		return \@transformed_queries;
	} else {
		return STATUS_WONT_HANDLE;
	}
}

1;
