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
	my $pid = $reporter->serverInfo('pid');

	if (defined $dbh) {
		say("Shutting down the server...");
		$dbh->func('shutdown', 'admin');
	}

	if (!windows()) {
		say("Waiting for mysqld with pid $pid to terminate...");
		foreach my $i (1..60) {
			if (! -e "/proc/$pid") {
				print "\n";
				last;
			}
			sleep(1);
			print "+";
		}
		say("... waiting complete.");
	}
	
	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_ALWAYS;
}

1;
