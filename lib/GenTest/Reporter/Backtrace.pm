package GenTest::Reporter::Backtrace;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use GenTest::Incident;

sub report {
	my $reporter = shift;
	my $datadir = $reporter->serverVariable('datadir');
	say("datadir is $datadir");
	my $binary = $reporter->serverInfo('binary');
	my $bindir = $reporter->serverInfo('bindir');

	my $pid = $reporter->serverInfo('pid');
	my $core = <$datadir/core*>;
	$core = </cores/core.$pid> if $^O eq 'darwin';
	say("Core file appears to be $core");

	my @commands;

	if (windows()) {
		$bindir =~ s{/}{\\}sgio;
		my $cdb_cmd = "!sym prompts off; !analyze -v; .ecxr; !for_each_frame dv /t;~*k;q";		
		push @commands, 'cdb -i "'.$bindir.'" -y "'.$bindir.';srv*C:\\cdb_symbols*http://msdl.microsoft.com/download/symbols" -z "'.$datadir.'\mysqld.dmp" -lines -c "'.$cdb_cmd.'"';
	} else {
		push @commands, "gdb --batch --se=$binary --core=$core --command=backtrace.gdb";
		push @commands, "gdb --batch --se=$binary --core=$core --command=backtrace-all.gdb";
	}
	
	if ($^O eq 'solaris') {
		push @commands, "echo '::stack' | mdb $core | c++filt";
	}

	my @debugs;

	foreach my $command (@commands) {
		my $output = `$command`;
		say("$output");
		push @debugs, [$command, $output];
	}


	my $incident = GenTest::Incident->new(
		corefile => $core,
		debugs => \@debugs
	);

	return STATUS_OK, $incident;
}

sub type {
	return REPORTER_TYPE_CRASH | REPORTER_TYPE_DEADLOCK;
}

1;
