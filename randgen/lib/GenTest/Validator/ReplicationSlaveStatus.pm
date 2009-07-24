package GenTest::Validator::ReplicationSlaveStatus;

require Exporter;
@ISA = qw(GenTest::Validator GenTest);

use strict;

use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

use constant SLAVE_STATUS_LAST_ERROR		=> 19;
use constant SLAVE_STATUS_LAST_SQL_ERROR	=> 35;
use constant SLAVE_STATUS_LAST_IO_ERROR		=> 38;

sub init {
	my ($validator, $executors) = @_;
	my $master_executor = $executors->[0];

	my ($slave_host, $slave_port) = $master_executor->slaveInfo();

	if (
		($slave_host eq '') || 
		($slave_port eq '')
	) {
		say("SHOW SLAVE HOSTS returns no data.");
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

	my $slave_status = $validator->dbh()->selectrow_arrayref("SHOW SLAVE STATUS");

	if ($slave_status->[SLAVE_STATUS_LAST_IO_ERROR] ne '') {
		say("Slave IO thread has stopped with error: ".$slave_status->[SLAVE_STATUS_LAST_IO_ERROR]);
		return STATUS_REPLICATION_FAILURE;
	} elsif ($slave_status->[SLAVE_STATUS_LAST_SQL_ERROR] ne '') {
		say("Slave SQL thread has stopped with error: ".$slave_status->[SLAVE_STATUS_LAST_SQL_ERROR]);
		return STATUS_REPLICATION_FAILURE;
	} elsif ($slave_status->[SLAVE_STATUS_LAST_ERROR] ne '') {
		say("Slave has stopped with error: ".$slave_status->[SLAVE_STATUS_LAST_ERROR]);
		return STATUS_REPLICATION_FAILURE;
        } else {
                return STATUS_OK;
        }
}

1;
