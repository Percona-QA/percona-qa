package GenTest::Reporter::ReplicationConnectionKiller;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;

my $tcpkill_pid;

use constant KILL_DURATION => 5;

sub monitor {
	local $SIG{INT} = sub {
		kill(15, $tcpkill_pid) if defined $tcpkill_pid;
		exit(STATUS_OK);
	};

	my $reporter = shift;

	my $dsn = $reporter->dsn();

	my $dbh = DBI->connect($dsn);

	my $slave_host = $reporter->serverInfo('slave_host');
	my $master_port = $reporter->serverVariable('port');

	# If interface is not specified, tcpkill will auto-pick the first available

	my $interface = $slave_host eq '127.0.0.1' ? 'lo' : '';

        my $slave_local = $dbh->selectrow_array("
		SELECT HOST
		FROM INFORMATION_SCHEMA.PROCESSLIST
		WHERE COMMAND = 'Binlog Dump'
	");
	
	my ($slave_local_host, $slave_local_port) = split (':', $slave_local);

	$tcpkill_pid = fork();

	if ($tcpkill_pid) {	# parent
		sleep(KILL_DURATION);
		say("Killing tcpkill with pid $tcpkill_pid");
		kill (15, $tcpkill_pid);
		$tcpkill_pid = undef;
		return(STATUS_OK);
	} else {
		my $command = "/usr/sbin/tcpkill -i $interface src host $slave_local_host and src port $slave_local_port and dst port $master_port";
		say("Executing $command");
		exec($command);
		exit(STATUS_OK);
	}
}

sub type {
	return REPORTER_TYPE_PERIODIC;
}

1;
