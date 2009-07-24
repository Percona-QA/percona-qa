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

	my ($slave_host, $slave_port) = $master_executor->slaveInfo();

	if (($slave_host ne '') && ($slave_port ne '')) {
		my $slave_dsn = 'dbi:mysql:host='.$slave_host.':port='.$slave_port.':user=root';
		my $slave_dbh = DBI->connect($slave_dsn, undef, undef, { RaiseError => 1 });
		$validator->setDbh($slave_dbh);
	}

	return 1;
}

sub validate {
	my ($validator, $executors, $results) = @_;

	my $master_executor = $executors->[0];

	my ($file, $pos) = $master_executor->masterStatus();
	return STATUS_OK if ($file eq '') || ($pos eq '');

	my $slave_dbh = $validator->dbh();
	return STATUS_OK if not defined $slave_dbh;

	my $wait_status = $slave_dbh->selectrow_array("SELECT MASTER_POS_WAIT(?, ?)", undef, $file, $pos);
	
	if (not defined $wait_status) {
		my @slave_status = $slave_dbh->selectrow_array("SHOW SLAVE STATUS");
		my $slave_status = $slave_status[37];
		say("Slave SQL thread has stopped with error: ".$slave_status);
		return STATUS_REPLICATION_FAILURE;
	} else {
		return STATUS_OK;
	}
}

1;
