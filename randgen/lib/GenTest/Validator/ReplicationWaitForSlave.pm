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

package GenTest::Validator::ReplicationWaitForSlave;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

sub init {
	my ($validator, $executors) = @_;
	my $master_executor = $executors->[0];

	my ($replica_host, $replica_port) = $master_executor->replicaInfo();

	if (($replica_host ne '') && ($replica_port ne '')) {
		my $replica_dsn = 'dbi:mysql:host='.$replica_host.':port='.$replica_port.':user=root';
		my $replica_dbh = DBI->connect($replica_dsn, undef, undef, { RaiseError => 1 });
		$validator->setDbh($replica_dbh);
	}

	return 1;
}

sub validate {
	my ($validator, $executors, $results) = @_;

	my $master_executor = $executors->[0];
	my $terms = $master_executor->replicationTerms();

	my ($file, $pos) = $master_executor->sourceStatus();
	return STATUS_OK if ($file eq '') || ($pos eq '');

	my $replica_dbh = $validator->dbh();
	return STATUS_OK if not defined $replica_dbh;

	my $wait_status = $replica_dbh->selectrow_array(
		"SELECT ".$terms->{pos_wait_func}."(?, ?)", undef, $file, $pos);

	if (not defined $wait_status) {
		my $replica_status = $replica_dbh->selectrow_hashref($terms->{replica_status});
		my $err = (defined $replica_status)
			? ($replica_status->{Last_SQL_Error} || $replica_status->{Last_Error} || '')
			: '';
		say("Replica SQL thread has stopped with error: ".$err);
		return STATUS_REPLICATION_FAILURE;
	} else {
		return STATUS_OK;
	}
}

1;
