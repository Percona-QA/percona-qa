# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
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

package GenTest::ReplicationTerms;

# MySQL/Percona 8.0.23 introduced SOURCE/REPLICA replication terminology as
# accepted aliases for the original MASTER/SLAVE terms; 8.4.0 then removed the
# original terms outright (STOP SLAVE / CHANGE MASTER TO / START SLAVE /
# SHOW MASTER STATUS / SHOW SLAVE STATUS / MASTER_POS_WAIT() / SHOW SLAVE HOSTS
# are hard syntax errors from 8.4 onward). MariaDB never made this change and
# only accepts the original terminology. Picking the wrong vocabulary fails
# replication setup/validation outright, so callers should obtain statements
# from this module based on the server version string.

use strict;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
	usesModernReplicationSyntax
	replicationTerms
);

my %LEGACY_REPLICATION_TERMS = (
	stop_replica          => 'STOP SLAVE',
	stop_replica_io       => 'STOP SLAVE IO_THREAD',
	change_source         => 'CHANGE MASTER TO',
	source_port           => 'MASTER_PORT',
	source_host           => 'MASTER_HOST',
	source_user           => 'MASTER_USER',
	source_connect_retry  => 'MASTER_CONNECT_RETRY',
	source_log_file       => 'MASTER_LOG_FILE',
	source_log_pos        => 'MASTER_LOG_POS',
	start_replica         => 'START SLAVE',
	start_replica_io      => 'START SLAVE IO_THREAD',
	binlog_status         => 'SHOW MASTER STATUS',
	pos_wait_func         => 'MASTER_POS_WAIT',
	replica_status        => 'SHOW SLAVE STATUS',
	replicas              => 'SHOW SLAVE HOSTS',
	# Semi-sync plugin: system/status variable names, not just statement
	# text. Confirmed live against Percona Server 9.7 -- the *_source_*/
	# *_replica_* names below don't exist there at all; only *_master_*/
	# *_slave_* do on a legacy-syntax server (installing the semisync_master/
	# semisync_slave plugins registers these names).
	semisync_source_enabled       => 'rpl_semi_sync_master_enabled',
	semisync_source_trace_level   => 'rpl_semi_sync_master_trace_level',
	semisync_source_timeout       => 'rpl_semi_sync_master_timeout',
	semisync_replica_enabled      => 'rpl_semi_sync_slave_enabled',
	semisync_replica_trace_level  => 'rpl_semi_sync_slave_trace_level',
	semisync_source_status        => 'Rpl_semi_sync_master_status',
	semisync_source_yes_tx        => 'Rpl_semi_sync_master_yes_tx',
	semisync_source_no_tx         => 'Rpl_semi_sync_master_no_tx',
);

my %MODERN_REPLICATION_TERMS = (
	stop_replica          => 'STOP REPLICA',
	stop_replica_io       => 'STOP REPLICA IO_THREAD',
	change_source         => 'CHANGE REPLICATION SOURCE TO',
	source_port           => 'SOURCE_PORT',
	source_host           => 'SOURCE_HOST',
	source_user           => 'SOURCE_USER',
	source_connect_retry  => 'SOURCE_CONNECT_RETRY',
	source_log_file       => 'SOURCE_LOG_FILE',
	source_log_pos        => 'SOURCE_LOG_POS',
	start_replica         => 'START REPLICA',
	start_replica_io      => 'START REPLICA IO_THREAD',
	binlog_status         => 'SHOW BINARY LOG STATUS',
	pos_wait_func         => 'SOURCE_POS_WAIT',
	replica_status        => 'SHOW REPLICA STATUS',
	replicas              => 'SHOW REPLICAS',
	# Confirmed live against Percona Server 9.7: installing
	# semisync_source.so/semisync_replica.so registers exactly these names
	# (SHOW VARIABLES/SHOW STATUS LIKE '%semi_sync%'); the legacy
	# rpl_semi_sync_master_*/rpl_semi_sync_slave_* names are not present.
	semisync_source_enabled       => 'rpl_semi_sync_source_enabled',
	semisync_source_trace_level   => 'rpl_semi_sync_source_trace_level',
	semisync_source_timeout       => 'rpl_semi_sync_source_timeout',
	semisync_replica_enabled      => 'rpl_semi_sync_replica_enabled',
	semisync_replica_trace_level  => 'rpl_semi_sync_replica_trace_level',
	semisync_source_status        => 'Rpl_semi_sync_source_status',
	semisync_source_yes_tx        => 'Rpl_semi_sync_source_yes_tx',
	semisync_source_no_tx         => 'Rpl_semi_sync_source_no_tx',
);

my %_modern_cache;
my %_binlog_status_cache;

sub usesModernReplicationSyntax {
	my ($version_string) = @_;
	return 0 if not defined $version_string;
	return $_modern_cache{$version_string} if exists $_modern_cache{$version_string};

	my $modern = 0;
	if ($version_string !~ m{mariadb}sio) {
		my ($major, $minor, $patch) = $version_string =~ m{^(\d+)\.(\d+)\.(\d+)}sio;
		if (defined $major &&
		    (($major > 8) ||
		     ($major == 8 && $minor > 0) ||
		     ($major == 8 && $minor == 0 && $patch >= 23))) {
			$modern = 1;
		}
	}

	$_modern_cache{$version_string} = $modern;
	return $modern;
}

# SHOW BINARY LOG STATUS (replacing SHOW MASTER STATUS) landed later than the
# rest of the SOURCE/REPLICA rollout: confirmed live that Percona Server
# 8.0.46 accepts SHOW REPLICA STATUS/SHOW REPLICAS/CHANGE REPLICATION SOURCE
# TO/SOURCE_POS_WAIT() but rejects SHOW BINARY LOG STATUS as a syntax error,
# while it works from MySQL 8.2.0 onward. Gate this term on its own boundary
# rather than the 8.0.23 one used for everything else.
sub usesBinaryLogStatusSyntax {
	my ($version_string) = @_;
	return 0 if not defined $version_string;
	return $_binlog_status_cache{$version_string} if exists $_binlog_status_cache{$version_string};

	my $modern = 0;
	if ($version_string !~ m{mariadb}sio) {
		my ($major, $minor, $patch) = $version_string =~ m{^(\d+)\.(\d+)\.(\d+)}sio;
		if (defined $major &&
		    (($major > 8) ||
		     ($major == 8 && $minor >= 2))) {
			$modern = 1;
		}
	}

	$_binlog_status_cache{$version_string} = $modern;
	return $modern;
}

sub replicationTerms {
	my ($version_string) = @_;
	my %terms = usesModernReplicationSyntax($version_string)
		? %MODERN_REPLICATION_TERMS
		: %LEGACY_REPLICATION_TERMS;

	$terms{binlog_status} = 'SHOW MASTER STATUS' if not usesBinaryLogStatusSyntax($version_string);

	return \%terms;
}

1;
