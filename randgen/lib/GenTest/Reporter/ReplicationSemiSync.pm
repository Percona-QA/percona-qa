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

package GenTest::Reporter::ReplicationSemiSync;

#
# The purpose of this Reporter is to test Semi-synchronous replication as follows:
#
#  At every monitoring cycle, we issue an adverse event against the replica or the source/replica connection and then:
#
# 1. Check that the replica IO thread is up to date with the source
#
# 2A. We wait for 1/2 of the timeout period, and then we check various counters to see that no transactions
#    have committed while the replica was not available OR
#
# 2B. We wait for more than the timeout period and then we check that some transactions have moved forward
#
# 3. We restart replication in order to allow the replica to catch up, and check that the source is back to
#    semisync replication
#

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;
use GenTest::ReplicationTerms qw(replicationTerms);

my $rpl_semi_sync_source_timeout = 10;

sub monitor {
	my $reporter = shift;

	say("GenTest::Reporter::ReplicationSemiSync: Test cycle starting.");

	my $prng = $reporter->prng();
	my $terms = replicationTerms($reporter->serverVariable('version'));

    my $replica_host;
    my $replica_port;
    my $source_dsn;
    if (defined $ENV{RQG_CALLBACK}) {
        $replica_host = $ENV{RQG_SLAVE_HOST};
        $replica_port = $ENV{RQG_SLAVE_PORT};
        $source_dsn = 'dbi:mysql:host='.$ENV{RQG_MASTER_HOST}.':port='.$ENV{RQG_MASTER_PORT}.':user=root';
    } else {
        $replica_host = $reporter->serverInfo('replica_host');
        $replica_port = $reporter->serverInfo('replica_port');
        $source_dsn = $reporter->dsn();
    }

	my $replica_dsn = 'dbi:mysql:host='.$replica_host.':port='.$replica_port.':user=root';

	my $replica_dbh = DBI->connect($replica_dsn);
	my $source_dbh = DBI->connect($source_dsn);

	$source_dbh->do("SET GLOBAL ".$terms->{semisync_source_enabled}." = 1");
	$source_dbh->do("SET GLOBAL ".$terms->{semisync_source_trace_level}." = 80");
	$replica_dbh->do("SET GLOBAL ".$terms->{semisync_replica_enabled}." = 1");
	$replica_dbh->do("SET GLOBAL ".$terms->{semisync_replica_trace_level}." = 80");

	return STATUS_REPLICATION_FAILURE if waitForReplica($source_dbh, $replica_dbh, 1, $terms);
# 	sleep(1);

# 	my ($unused2, $rpl_semi_sync_master_status_first) = $master_dbh->selectrow_array("SHOW STATUS LIKE 'Rpl_semi_sync_master_status'");

# 	if (
# 		($rpl_semi_sync_master_status_first eq '') ||
# 		($rpl_semi_sync_master_status_first eq 'OFF')
# 	) {
# 		say("GenTest::Reporter::ReplicationSemiSync: Semisync replication is not enabled: rpl_semi_sync_master_status = $rpl_semi_sync_master_status_first.");
# 		return STATUS_REPLICATION_FAILURE;
# 	}

#	$master_dbh->do("SET GLOBAL rpl_semi_sync_master_timeout = ".($rpl_semi_sync_master_timeout * 1000));
#	say("GenTest::Reporter::ReplicationSemiSync: Acquiring the global read lock.");
#	$master_dbh->do("FLUSH NO_WRITE_TO_BINLOG TABLES WITH READ LOCK");
#	say("GenTest::Reporter::ReplicationSemiSync: stopping slave IO thread.");
#	$slave_dbh->do("STOP SLAVE IO_THREAD");
#	say("GenTest::Reporter::ReplicationSemiSync: stopped slave IO thread.");

#	return STATUS_REPLICATION_FAILURE if isSlaveBehind($master_dbh, $slave_dbh);

#	$master_dbh->do("FLUSH NO_WRITE_TO_BINLOG STATUS");
#	say("GenTest::Reporter::ReplicationSemiSync: Flushed status.");
#	$master_dbh->do("UNLOCK TABLES");
#	say("GenTest::Reporter::ReplicationSemiSync: Released the global read lock.");
#	my ($unusedA, $rpl_semi_sync_master_yes_tx_atflush) = $master_dbh->selectrow_array("SHOW STATUS LIKE 'Rpl_semi_sync_master_yes_tx'");
#	my ($unusedB, $rpl_semi_sync_master_no_tx_atflush) = $master_dbh->selectrow_array("SHOW STATUS LIKE 'Rpl_semi_sync_master_no_tx'");

	# Pick a sleep interval that is either more or less than the semisync timeout

	my $sleep_interval = $prng->int(0, 1) == 1 ? ($rpl_semi_sync_source_timeout * 2) : 5;
	say("GenTest::Reporter::ReplicationSemiSync: Sleeping for $sleep_interval seconds.");
	sleep($sleep_interval);

	my ($unused4, $rpl_semi_sync_source_yes_tx) = $source_dbh->selectrow_array("SHOW STATUS LIKE '".$terms->{semisync_source_yes_tx}."'");
	my ($unused5, $rpl_semi_sync_source_no_tx) = $source_dbh->selectrow_array("SHOW STATUS LIKE '".$terms->{semisync_source_no_tx}."'");
	my ($unused6, $rpl_semi_sync_source_status_after) = $source_dbh->selectrow_array("SHOW STATUS LIKE '".$terms->{semisync_source_status}."'");

	#
	# If we slept more than the semisync timeout, then we can expect that transactions have been committed
	# If we slept less, then no transactions should have committed
	#

	if ($sleep_interval > $rpl_semi_sync_source_timeout) {
                if ($rpl_semi_sync_source_status_after eq 'ON') {
                        say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{semisync_source_status}." = ON even after stopping for longer than the timeout.");
                        return STATUS_REPLICATION_FAILURE;
                } elsif ($rpl_semi_sync_source_no_tx == 0) {
			say("GenTest::Reporter::ReplicationSemiSync: Transactions were not committed asynchronously while replica was stopped for longer than the timeout.");
			say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{semisync_source_no_tx}." = $rpl_semi_sync_source_no_tx;");
		} elsif ($rpl_semi_sync_source_yes_tx > 0) {
			say("GenTest::Reporter::ReplicationSemiSync: Transactions were committed semisynchronously while replica was stopped longer than the timeout.");
			say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{semisync_source_yes_tx}." = $rpl_semi_sync_source_yes_tx;");
			return STATUS_REPLICATION_FAILURE;
		}
	} else {

#		jasonh says that this condition is not guaranteed - if we detect a replica problem, we abort immediately and do not bother
#		to wait for the full timeout
#
		if ($rpl_semi_sync_source_status_after eq 'OFF') {
			say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{semisync_source_status}." = OFF even after stopping for less than the timeout.");
			return STATUS_REPLICATION_FAILURE;
		} elsif ($rpl_semi_sync_source_no_tx > 0) {
			say("GenTest::Reporter::ReplicationSemiSync: Transactions were committed asynchronously while replica was stopped for less than the timeout.");
			say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{semisync_source_no_tx}." = $rpl_semi_sync_source_no_tx;");
			return STATUS_REPLICATION_FAILURE;
		} elsif ($rpl_semi_sync_source_yes_tx > 0) {
			say("GenTest::Reporter::ReplicationSemiSync: Transactions were committed semisynchronously while replica was stopped for less than the timeout.");
			say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{semisync_source_yes_tx}." = $rpl_semi_sync_source_yes_tx;");
			return STATUS_REPLICATION_FAILURE;
		} else {
#			return STATUS_REPLICATION_FAILURE if isReplicaBehind($source_dbh, $replica_dbh);
		}
	}

	say("GenTest::Reporter::ReplicationSemiSync: Starting replica IO thread.");
	$replica_dbh->do($terms->{start_replica_io});

	#
	# Make sure source and replica can reconcile and semisync will be turned on again
	#

	return STATUS_REPLICATION_FAILURE if waitForReplica($source_dbh, $replica_dbh, 0, $terms);
# 	sleep(1);

# 	my ($unused7, $rpl_semi_sync_master_status_last) = $master_dbh->selectrow_array("SHOW STATUS LIKE 'Rpl_semi_sync_master_status'");
# 	if ($rpl_semi_sync_master_status_last eq 'OFF') {
# 		say("GenTest::Reporter::ReplicationSemiSync: Master has failed to return to semisync replication even after the slave has reconnected.");
# 		return STATUS_REPLICATION_FAILURE;
# 	}

# 	say("GenTest::Reporter::ReplicationSemiSync: test cycle ending with Rpl_semi_sync_master_status = $rpl_semi_sync_master_status_last.");

	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_PERIODIC;
}

sub isReplicaBehind {
	my ($source_dbh, $replica_dbh, $terms) = @_;

	my $binlogs = $source_dbh->selectall_arrayref("SHOW BINARY LOGS");
	my ($last_log_name, $last_log_pos) = ($binlogs->[$#$binlogs]->[0], $binlogs->[$#$binlogs]->[1]);
	my ($last_log_id) = $last_log_name =~ m{(\d+)}sgio;
	say("Source: last_log_name = $last_log_name; last_log_pos = $last_log_pos; $last_log_id = $last_log_id.");

	my $replica_status = $replica_dbh->selectrow_hashref($terms->{replica_status});
	my $source_log_file = $replica_status->{Source_Log_File} // $replica_status->{Master_Log_File};
	my $read_source_log_pos = $replica_status->{Read_Source_Log_Pos} // $replica_status->{Read_Master_Log_Pos};
	my ($source_log_id) = $source_log_file =~ m{(\d+)}sgio;
	say("GenTest::Reporter::ReplicationSemiSync: replica: source_log_file = $source_log_file; read_source_log_pos = $read_source_log_pos; source_log_id = $source_log_id.");
	if (
		($last_log_id < $source_log_id) ||
		($last_log_id == $source_log_id) && ($last_log_pos > $read_source_log_pos)
	) {
		my ($unused, $rpl_semi_sync_source_status) = $source_dbh->selectrow_array("SHOW STATUS LIKE '".$terms->{semisync_source_status}."'");
		say("GenTest::Reporter::ReplicationSemiSync: Replica has lagged behind while ".$terms->{semisync_source_status}." = $rpl_semi_sync_source_status.");
		return STATUS_REPLICATION_FAILURE;
	}
}

sub waitForReplica {
	my ($source_dbh, $replica_dbh, $stop_replica, $terms) = @_;

	say("GenTest::Reporter::ReplicationSemiSync: Flushing tables with read lock on source...");
	$source_dbh->do("FLUSH NO_WRITE_TO_BINLOG TABLES WITH READ LOCK");
	say("GenTest::Reporter::ReplicationSemiSync: ... flushed.");

	my ($file, $pos) = $source_dbh->selectrow_array($terms->{binlog_status});

	if (($file eq '') || ($pos eq '')) {
		 say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{binlog_status}." failed.");
		 return STATUS_REPLICATION_FAILURE;
	}

	say("GenTest::Reporter::ReplicationSemiSync: Waiting for replica...");
	my $wait_status = $replica_dbh->selectrow_array(
		"SELECT ".$terms->{pos_wait_func}."(?, ?)", undef, $file, $pos);
	say("GenTest::Reporter::ReplicationSemiSync: ... replica caught up with source.");

	my ($unused2, $rpl_semi_sync_source_status) = $source_dbh->selectrow_array("SHOW STATUS LIKE '".$terms->{semisync_source_status}."'");
	if (not $rpl_semi_sync_source_status eq 'ON') {
	    say("GenTest::Reporter::ReplicationSemiSync: Source has failed to return to semisync replication even after the replica has caught up.");
	    return STATUS_REPLICATION_FAILURE;
	}

	if ($stop_replica) {
	    $source_dbh->do("FLUSH NO_WRITE_TO_BINLOG STATUS");
	    say("GenTest::Reporter::ReplicationSemiSync: Flushed status.");
	    $source_dbh->do("SET GLOBAL ".$terms->{semisync_source_timeout}." = ".($rpl_semi_sync_source_timeout * 1000));
	    say("GenTest::Reporter::ReplicationSemiSync: stopping replica IO thread.");
	    $replica_dbh->do($terms->{stop_replica_io});
	    say("GenTest::Reporter::ReplicationSemiSync: stopped replica IO thread.");
	}

	$source_dbh->do("UNLOCK TABLES");

	if (not defined $wait_status) {
		say("GenTest::Reporter::ReplicationSemiSync: ".$terms->{pos_wait_func}."() has failed. Replica SQL thread has likely stopped.");
		return STATUS_REPLICATION_FAILURE;
	}
	return 0;
}

1;
