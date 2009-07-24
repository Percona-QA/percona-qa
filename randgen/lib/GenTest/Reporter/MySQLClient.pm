package GenTest::Reporter::MySQLClient;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use File::Copy;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;

sub report {
	my $reporter = shift;

	system("mysql -uroot --protocol=tcp --port=19306 test");
	
	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_DATA ;
}

1;
