package GenTest::Reporter::ReplicationLogFlusher;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;

sub monitor {

	my $reporter = shift;

	my $dsn = $reporter->dsn();
	my $dbh = DBI->connect($dsn);
	$dbh->do("FLUSH LOGS");
	return STATUS_OK;

}

sub type {
	return REPORTER_TYPE_PERIODIC;
}

1;
