package GenTest::Reporter::Shutdown;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;

sub report {
	my $reporter = shift;

	my $dbh = DBI->connect($reporter->dsn(), undef, undef, {PrintError => 0});

	say("Shutting down the server.");

	if (defined $dbh) {
		$dbh->func('shutdown', 'admin');
	}
	
	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_ALWAYS;
}

1;
