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

package GenTest::Validator::ReplicationSlaveStatus;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Executor::MySQL;

# Previously hardcoded positional indices into SHOW SLAVE STATUS output
# (19/35/38) -- fragile by construction, since MySQL has added columns to
# this output across versions, and confirmed actually wrong on a live
# Percona Server 9.7 build (Last_IO_Error sits at position 35, Last_SQL_Error
# at 37, not 38/35). Switched to name-based access below instead: MySQL kept
# the column names Last_Error/Last_IO_Error/Last_SQL_Error unchanged when it
# renamed the statement itself to SHOW REPLICA STATUS in 8.0.23+, so
# selectrow_hashref() works correctly regardless of which statement variant
# ran, with no version-dependent column positions to track.

sub init {
	my ($validator, $executors) = @_;
	my $master_executor = $executors->[0];

	my ($slave_host, $slave_port) = $master_executor->slaveInfo();

	if (
		($slave_host eq '') ||
		($slave_port eq '')
	) {
		say("SHOW REPLICAS / SHOW SLAVE HOSTS returned no data.");
		return STATUS_REPLICATION_FAILURE;
	}
	my $slave_dsn = 'dbi:mysql:host='.$slave_host.':port='.$slave_port.':user=root';

	my $slave_dbh = DBI->connect($slave_dsn, undef, undef, { PrintError => 0 });
	$validator->setDbh($slave_dbh);
	return STATUS_OK;
}

sub validate {
	my ($validator, $executors, $results) = @_;

	my $master_executor = $executors->[0];

	# init() may have failed to obtain a slave connection (e.g. slaveInfo()
	# found no registered replica) without that being surfaced here -- guard
	# rather than crash the whole worker on ->selectrow_hashref() against an
	# undef $dbh.
	my $dbh = $validator->dbh();
	return STATUS_WONT_HANDLE if not defined $dbh;

	my $modern = GenTest::Executor::MySQL::_usesModernReplicationSyntax($master_executor->version());
	my $slave_status = $dbh->selectrow_hashref($modern ? "SHOW REPLICA STATUS" : "SHOW SLAVE STATUS");
	return STATUS_WONT_HANDLE if not defined $slave_status;

	for my $error_column (qw(Last_IO_Error Last_SQL_Error Last_Error)) {
		if (defined $slave_status->{$error_column} && $slave_status->{$error_column} ne '') {
			say("Replica has stopped with error ($error_column): ".$slave_status->{$error_column});
			return STATUS_REPLICATION_FAILURE;
		}
	}
	return STATUS_OK;
}

1;
