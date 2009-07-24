package GenTest::Reporter::WinPackage;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use File::Copy;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;

sub report {
	my $reporter = shift;
	my $bindir = $reporter->serverInfo('bindir');
	my $datadir = $reporter->serverVariable('datadir');
	$datadir =~ s{[\\/]$}{}sgio;

	if (windows()) {
		foreach my $file ('mysqld.exe', 'mysqld.pdb') {
			my $old_loc = $bindir.'\\'.$file;
			my $new_loc = $datadir.'\\'.$file;
			say("Copying $old_loc to $new_loc .");
			copy($old_loc, $new_loc);
		}
	}
	
	return STATUS_OK;
}

sub type {
	return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK ;
}

1;
