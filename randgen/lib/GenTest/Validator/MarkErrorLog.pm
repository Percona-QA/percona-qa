package GenTest::Validator::MarkErrorLog;

require Exporter;
@ISA = qw(GenTest::Validator);

use strict;
use GenTest;
use GenTest::Validator;
use GenTest::Constants;

my $error_log;

sub validate {
        my ($validator, $executors, $results) = @_;
	my $dbh = $executors->[0]->dbh();

	if (not defined $error_log) {
		my ($foo, $error_log_mysql) = $dbh->selectrow_array("SHOW VARIABLES LIKE 'log_error'");

		if ($error_log_mysql ne '') {
			$error_log = $error_log_mysql;
		} else {
			my ($bar, $datadir_mysql) = $dbh->selectrow_array("SHOW VARIABLES LIKE 'datadir'");
			$error_log = $datadir_mysql.'../log/master.err';
		}
	}
	
	my $query = $results->[0]->query();
	
	open(LOG, ">>$error_log") or die "unable to open $error_log: $!";
	print LOG localtime()." [$$] Query: $query\n";
	close LOG;

	return STATUS_OK;
}

1;
