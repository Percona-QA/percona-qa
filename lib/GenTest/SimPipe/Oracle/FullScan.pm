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

package GenTest::SimPipe::Oracle::FullScan;

require Exporter;
@ISA = qw(GenTest::SimPipe::Oracle GenTest);
@EXPORT = qw();

use strict;
use DBI;
use GenTest;
use GenTest::SimPipe::Oracle;
use GenTest::Constants;
use GenTest::Executor;
use GenTest::Comparator;

1;

sub oracle {
	my ($oracle, $testcase) = @_;

	my $executor = GenTest::Executor->newFromDSN($oracle->dsn());
	$executor->init();
	
	my $dbh = $executor->dbh();

	$dbh->do("CREATE DATABASE IF NOT EXISTS fullscan; USE fullscan");

	$dbh->do($testcase->mysqldOptionsToString());
	$dbh->do($testcase->dbObjectsToString());

	my $original_query = $testcase->queries()->[0];

	my $original_result = $executor->execute($original_query);

	my @table_names = @{$dbh->selectcol_arrayref("SHOW TABLES")};
	foreach my $table_name (@table_names) {
		$dbh->do("ALTER TABLE $table_name DISABLE KEYS");
	}

	$dbh->do("SET SESSION join_cache_level = 0");
	$dbh->do("SET SESSION optimizer_use_mrr = 'disable'");
	$dbh->do("SET SESSION optimizer_switch='index_condition_pushdown=off'");

	my $fullscan_result = $executor->execute($original_query);

	$dbh->do("DROP DATABASE fullscan");

        my $compare_outcome = GenTest::Comparator::compare($original_result, $fullscan_result);

	if (
		($original_result->status() != STATUS_OK) ||
		($fullscan_result->status() != STATUS_OK) ||
		($compare_outcome == STATUS_OK)
	) {
		return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
	} else {
		return ORACLE_ISSUE_STILL_REPEATABLE;
	}	
}

1;
