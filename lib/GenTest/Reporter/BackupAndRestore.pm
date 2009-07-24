package GenTest::Reporter::BackupAndRestore;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;

my $count = 0;
my $file = '/tmp/rqg_backup';

sub monitor {
	my $reporter = shift;

	return STATUS_OK if $count > 0;

	my $dsn = $reporter->dsn();

	my $dbh = DBI->connect($dsn);

	unlink('/tmp/rqg_backup');
	say("Executing BACKUP DATABASE.");
	$dbh->do("BACKUP DATABASE test TO '/tmp/rqg_backup'");
	$count++;

	if (defined $dbh->err()) {
		return STATUS_DATABASE_CORRUPTION;
	} else {
		return STATUS_OK;
	}
}

sub report {
	my $reporter = shift;

	my $dsn = $reporter->dsn();

	my $dbh = DBI->connect($dsn);

	say("Executing RESTORE FROM.");
	$dbh->do("RESTORE FROM '/tmp/rqg_backup' OVERWRITE");

	if (defined $dbh->err()) {
		return STATUS_DATABASE_CORRUPTION;
	} else {
		return STATUS_OK;
	}
}

sub type {
	return REPORTER_TYPE_PERIODIC | REPORTER_TYPE_SUCCESS;
}

1;
