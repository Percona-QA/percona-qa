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

package GenTest::Reporter::ReplicationConsistency;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;

my $reporter_called = 0;

sub report {
	my $reporter = shift;

	return STATUS_WONT_HANDLE if $reporter_called == 1;
	$reporter_called = 1;

	my $master_dbh = DBI->connect($reporter->dsn(), undef, undef, {PrintError => 0});
        my ($binlog_file, $binlog_pos) = $master_dbh->selectrow_array("SHOW MASTER STATUS");

	my @all_databases = @{$master_dbh->selectcol_arrayref("SHOW DATABASES")};
	my $databases_string = join(' ', grep { $_ !~ m{^(mysql|information_schema|performance_schema)$}sgio } @all_databases );

	my $master_port = $reporter->serverVariable('port');
	my $slave_port = $master_port + 2;

        my $slave_dsn = "dbi:mysql:host=127.0.0.1:port=".$slave_port.":user=root";
        my $slave_dbh = DBI->connect($slave_dsn, undef, undef, { PrintError => 1 } );

	return STATUS_REPLICATION_FAILURE if not defined $slave_dbh;

	$slave_dbh->do("START SLAVE");

	say("Executing: MASTER_POS_WAIT(): binlog_file: $binlog_file, binlog_pos: $binlog_pos.");
	my $wait_result = $slave_dbh->selectrow_array("SELECT MASTER_POS_WAIT('$binlog_file',$binlog_pos)");

	if (not defined $wait_result) {
		say("MASTER_POS_WAIT() failed in slave on port $slave_port. Slave replication thread not running.");
		return STATUS_REPLICATION_FAILURE;
	} else {
		say("MASTER_POS_WAIT() complete.");
	}
	
	my @dump_ports = ($master_port , $slave_port);
	my @dump_files;

	foreach my $i (0..$#dump_ports) {
		say("Dumping server on port $dump_ports[$i]...");
		$dump_files[$i] = tmpdir()."/server_".$$."_".$i.".dump";
		my $dump_result = system('"'.$reporter->serverInfo('client_bindir')."/mysqldump\" --hex-blob --no-tablespaces --skip-triggers --compact --order-by-primary --skip-extended-insert --no-create-info --host=127.0.0.1 --port=$dump_ports[$i] --user=root --databases $databases_string | sort > $dump_files[$i]");
		return STATUS_ENVIRONMENT_FAILURE if $dump_result > 0;
	}

	say("Comparing SQL dumps between servers on ports $dump_ports[0] and $dump_ports[1] ...");
	my $diff_result = system("diff -u $dump_files[0] $dump_files[1]");
	$diff_result = $diff_result >> 8;

	foreach my $dump_file (@dump_files) {
		unlink($dump_file);
	}

	if ($diff_result == 0) {
		say("No differences were found between servers.");
		return STATUS_OK;
	} else {
		say("Servers have diverged.");
		return STATUS_REPLICATION_FAILURE;
	}
}

sub type {
	return REPORTER_TYPE_SUCCESS;
}

1;
