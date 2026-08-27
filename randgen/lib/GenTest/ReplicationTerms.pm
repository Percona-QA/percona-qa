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
);

my %_modern_cache;

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

sub replicationTerms {
	my ($version_string) = @_;
	return usesModernReplicationSyntax($version_string)
		? \%MODERN_REPLICATION_TERMS
		: \%LEGACY_REPLICATION_TERMS;
}

1;
