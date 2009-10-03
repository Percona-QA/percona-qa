package GenTest::Reporter::QueryTimeout;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;

use constant PROCESSLIST_CONNECTION_ID		=> 0;
use constant PROCESSLIST_PROCESS_TIME		=> 5;
use constant PROCESSLIST_PROCESS_STATE		=> 6;
use constant PROCESSLIST_PROCESS_INFO		=> 7;

# Minimum lifetime for a query before it is killed
use constant QUERY_LIFETIME_THRESHOLD		=> 5;	# Seconds

sub monitor {
	my $reporter = shift;

	my $dsn = $reporter->dsn();
	my $dbh = DBI->connect($dsn);

	if (defined GenTest::Executor::MySQL::errorType($DBI::err)) {
		return GenTest::Executor::MySQL::errorType($DBI::err);
	} elsif (not defined $dbh) {
		return STATUS_UNKNOWN_ERROR;
	}

	my $processlist = $dbh->selectall_arrayref("SHOW FULL PROCESSLIST");

	foreach my $process (@$processlist) {
		if (
			($process->[PROCESSLIST_PROCESS_INFO] ne '') &&
			($process->[PROCESSLIST_PROCESS_TIME] > QUERY_LIFETIME_THRESHOLD)
		) {
			say("Query: ".$process->[PROCESSLIST_PROCESS_INFO]." is taking more than ".(QUERY_LIFETIME_THRESHOLD). " seconds. Killing query.");
			$dbh->do("KILL QUERY ".$process->[PROCESSLIST_CONNECTION_ID]);
		}
	}

	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_PERIODIC;
}

1;
