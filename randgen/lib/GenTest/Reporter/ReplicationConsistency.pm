# Copyright (c) 2013, Monty Program Ab.
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
use GenTest::ReplicationTerms qw(replicationTerms);

my $reporter_called = 0;

sub report {
	my $reporter = shift;

	return STATUS_WONT_HANDLE if $reporter_called == 1;
	$reporter_called = 1;

	my $source_dbh = DBI->connect($reporter->dsn(), undef, undef, {PrintError => 0});
	my $source_port = $reporter->serverVariable('port');
	my $replica_port;

	my $terms = replicationTerms($reporter->serverVariable('version'));
	my $replica_info = $source_dbh->selectrow_arrayref($terms->{replicas});
	if (defined $replica_info) {
		$replica_port = $replica_info->[2];
	} else {
		$replica_port = $source_port + 2;
	}

        my $replica_dsn = "dbi:mysql:host=127.0.0.1:port=".$replica_port.":user=root";
        my $replica_dbh = DBI->connect($replica_dsn, undef, undef, { PrintError => 1 } );

	return STATUS_REPLICATION_FAILURE if not defined $replica_dbh;

	$replica_dbh->do($terms->{start_replica});

	#
	# We call MASTER_POS_WAIT / SOURCE_POS_WAIT at 100K increments in order
	# to avoid buildbot timeout in case one big wait would take more than
	# 20 minutes.
	#

	my $sth_binlogs = $source_dbh->prepare("SHOW BINARY LOGS");
	$sth_binlogs->execute();
	while (my ($intermediate_binlog_file, $intermediate_binlog_size) = $sth_binlogs->fetchrow_array()) {
		my $intermediate_binlog_pos = $intermediate_binlog_size < 10000000 ? $intermediate_binlog_size : 10000000;
		do {
			say("Executing intermediate ".$terms->{pos_wait_func}."('$intermediate_binlog_file', $intermediate_binlog_pos).");
			my $intermediate_wait_result = $replica_dbh->selectrow_array(
				"SELECT ".$terms->{pos_wait_func}."('$intermediate_binlog_file',$intermediate_binlog_pos)");
			if (not defined $intermediate_wait_result) {
				say("Intermediate ".$terms->{pos_wait_func}."('$intermediate_binlog_file', $intermediate_binlog_pos) failed in replica on port $replica_port. Replica replication thread not running.");
				return STATUS_REPLICATION_FAILURE;
			}
			$intermediate_binlog_pos += 10000000;
	        } while (  $intermediate_binlog_pos <= $intermediate_binlog_size );
	}

        my ($final_binlog_file, $final_binlog_pos) = $source_dbh->selectrow_array($terms->{binlog_status});

	say("Executing final ".$terms->{pos_wait_func}."('$final_binlog_file', $final_binlog_pos).");
	my $final_wait_result = $replica_dbh->selectrow_array(
		"SELECT ".$terms->{pos_wait_func}."('$final_binlog_file',$final_binlog_pos)");

	if (not defined $final_wait_result) {
		say("Final ".$terms->{pos_wait_func}."('$final_binlog_file', $final_binlog_pos) failed in replica on port $replica_port. Replica replication thread not running.");
		return STATUS_REPLICATION_FAILURE;
	} else {
		say("Final ".$terms->{pos_wait_func}."('$final_binlog_file', $final_binlog_pos) complete.");
	}

	my @all_databases = @{$source_dbh->selectcol_arrayref("SHOW DATABASES")};
	my $databases_string = join(' ', grep { $_ !~ m{^(mysql|information_schema|performance_schema)$}sgio } @all_databases );
	
	my @dump_ports = ($source_port , $replica_port);
	my @dump_files;

	foreach my $i (0..$#dump_ports) {
		say("Dumping server on port $dump_ports[$i]...");
		$dump_files[$i] = tmpdir()."/server_".abs($$)."_".$i.".dump";
		my $dump_result = system('"'.$reporter->serverInfo('client_bindir')."/mysqldump\" --hex-blob --no-tablespaces --skip-triggers --compact --order-by-primary --skip-extended-insert --no-create-info --host=127.0.0.1 --port=$dump_ports[$i] --user=root --password='' --databases $databases_string | sort > $dump_files[$i]");
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
