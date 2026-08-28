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

package GenTest::Reporter::ReplicationThreadRestarter;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;
use GenTest::ReplicationTerms qw(replicationTerms);

sub monitor {

	my $reporter = shift;

	my $prng = $reporter->prng();

	my $replica_host = $reporter->serverInfo('replica_host');
	my $replica_port = $reporter->serverInfo('replica_port');

	my $replica_dsn = 'dbi:mysql:host='.$replica_host.':port='.$replica_port.':user=root';
	my $replica_dbh = DBI->connect($replica_dsn);

	my $terms = replicationTerms($reporter->serverVariable('version'));

	my $verb = $prng->arrayElement(['START','STOP']);
	my $threads = $prng->arrayElement([
		'',
		'IO_THREAD',
		'IO_THREAD, SQL_THREAD',
		'SQL_THREAD, IO_THREAD',
		'SQL_THREAD'
	]);

	my $query = $verb.' '.$terms->{replica_keyword}.' '.$threads;

	if (defined $replica_dbh) {
		$replica_dbh->do($query);
		if ($replica_dbh->err()) {
			say("Query: $query failed: ".$replica_dbh->errstr());
			return STATUS_REPLICATION_FAILURE;
		} else {
			return STATUS_OK;
		}
	} else {
		return STATUS_SERVER_CRASHED;
	}
}

sub type {
	return REPORTER_TYPE_PERIODIC;
}

1;
