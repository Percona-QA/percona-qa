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

package GenTest::Reporter::ReplicationAnalyzeTable;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;

1;

sub monitor {
	my $reporter = shift;

	my $replica_host = $reporter->serverInfo('replica_host');
	my $replica_port = $reporter->serverInfo('replica_port');

	my $source_dsn = $reporter->dsn();
	my $replica_dsn = 'dbi:mysql:host='.$replica_host.':port='.$replica_port.':user=root';

	my $replica_dbh = DBI->connect($replica_dsn);

	my $databases = $replica_dbh->selectcol_arrayref("SHOW DATABASES");
	foreach my $database (@$databases) {
		next if $database =~ m{^(mysql|information_schema|pbxt|performance_schema)$}sio;
                my $tables = $replica_dbh->selectcol_arrayref("SHOW TABLES FROM `$database`");
                foreach my $table (@$tables) {
			$replica_dbh->do("ANALYZE TABLE `$database`.`$table`");
		}
	}

	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_PERIODIC ;
}

1;
