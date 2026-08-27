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

# Error columns are read by name via selectrow_hashref(). Positional indices
# into SHOW SLAVE/REPLICA STATUS have shifted across MySQL versions; the
# Last_*_Error column names themselves were kept stable through the
# SOURCE/REPLICA rename.

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
	if (not defined $slave_dbh) {
		say("Unable to connect to replica at $slave_dsn");
		return STATUS_REPLICATION_FAILURE;
	}
	$validator->setDbh($slave_dbh);
	return STATUS_OK;
}

sub validate {
	my ($validator, $executors, $results) = @_;

	my $master_executor = $executors->[0];

	my $dbh = $validator->dbh();
	if (not defined $dbh) {
		say("Replica connection is gone; cannot check replication status.");
		return STATUS_REPLICATION_FAILURE;
	}

	my $terms = $master_executor->replicationTerms();
	my $slave_status = $dbh->selectrow_hashref($terms->{replica_status});
	if (not defined $slave_status) {
		say("SHOW REPLICA/SLAVE STATUS returned no data.");
		return STATUS_REPLICATION_FAILURE;
	}

	for my $error_column (qw(Last_IO_Error Last_SQL_Error Last_Error)) {
		if (defined $slave_status->{$error_column} && $slave_status->{$error_column} ne '') {
			say("Replica has stopped with error ($error_column): ".$slave_status->{$error_column});
			return STATUS_REPLICATION_FAILURE;
		}
	}
	return STATUS_OK;
}

1;
