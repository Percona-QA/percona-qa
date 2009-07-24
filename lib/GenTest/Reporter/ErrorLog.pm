package GenTest::Reporter::ErrorLog;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Reporter;
use GenTest::Constants;

sub report {
	my $reporter = shift;

	# master.err-old is created when logs are rotated due to SIGHUP

	my $main_log = $reporter->serverVariable('log_error');
	$main_log = $reporter->serverVariable('datadir')."../log/master.err" if $main_log eq '';

	foreach my $log ( $main_log, $main_log.'-old' ) {
		if ((-e $log) && (-s $log > 0)) {
			say("The last 100 lines from $log :");
			system("tail -100 $log");
		}
	}
	
	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK ;
}

1;
