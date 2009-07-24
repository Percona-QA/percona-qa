package GenTest::Reporter::ReplicationThreadRestarter;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;

sub monitor {

	my $reporter = shift;

	my $prng = $reporter->prng();

	my $slave_host = $reporter->serverInfo('slave_host');
	my $slave_port = $reporter->serverInfo('slave_port');

	my $slave_dsn = 'dbi:mysql:host='.$slave_host.':port='.$slave_port.':user=root';
	my $slave_dbh = DBI->connect($slave_dsn);

	my $verb = $prng->arrayElement(['START','STOP']);
	my $threads = $prng->arrayElement([
		'',
		'IO_THREAD',
		'IO_THREAD, SQL_THREAD',
		'SQL_THREAD, IO_THREAD',
		'SQL_THREAD'
	]);

	my $query = $verb.' SLAVE '.$threads;

	if (defined $slave_dbh) {
		$slave_dbh->do($query);
		if ($slave_dbh->err()) {
			say("Query: $query failed: ".$slave_dbh->errstr());
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
