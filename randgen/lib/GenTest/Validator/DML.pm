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
#

package GenTest::Validator::DML;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use GenTest;
use GenTest::Comparator;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use Time::HiRes;

sub validate {
	my ($validator, $executors, $results) = @_;
	my $executor = $executors->[0];
	my $dbh = $executor->dbh();
	my $orig_result = $results->[0];
	my $orig_query = $orig_result->query();

	return STATUS_WONT_HANDLE if $orig_query !~ m{INSERT|UPDATE|DELETE}sio;
	return STATUS_WONT_HANDLE if $orig_result->status() != STATUS_OK;

	$dbh->do("ROLLBACK");
	my $join_cache_level = $dbh->selectrow_array('SELECT @@join_cache_level');

	$dbh->do("SET SESSION join_cache_level = 0");
	$dbh->do("START TRANSACTION");
	my $oracle_result = $executor->execute($orig_query);
	$dbh->do("ROLLBACK");
	$dbh->do("SET SESSION join_cache_level = $join_cache_level");

	if ($orig_result->status() != $oracle_result->status()) {
		say("Query: $orig_query; had a different STATUS when executed without optimizations.");
		return STATUS_ERROR_MISMATCH;
	} elsif ($orig_result->affectedRows() != $oracle_result->affectedRows()) {
		say("Query: $orig_query; affected a different number of rows when run with no optimizations.");
		return STATUS_LENGTH_MISMATCH;
	} elsif ($orig_result->matchedRows() != $oracle_result->matchedRows()) {
		say("Query: $orig_query; matched a different number of rows when run with no optimizations.");
		return STATUS_LENGTH_MISMATCH;
	} elsif ($orig_result->changedRows() != $oracle_result->changedRows()) {
		say("Query: $orig_query; changed a different number of rows when run with no optimizations.");
		return STATUS_LENGTH_MISMATCH;
	} else {
		return STATUS_OK;
	}
}

1;
