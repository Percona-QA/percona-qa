use strict;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest;
use GenTest::Constants;
use GenTest::Simplifier::Mysqltest;

#
# Please modify those settings to fit your environment before you run this script
#

my $input_file = '/tmp/crashedtable.test';
my $basedir = '/build/bzr/5.1-bugteam';
my $expected_mtr_output = 'crashed';

my @mtr_options = (
	'--skip-ndbcluster',
	'--record',
	'--mem',
	'--no-check-testcases'
);

my $replication = 0; # Set to 1 to turn on --source include/master-slave.inc and --sync_slave_with_master

# End of user-configurable section

my $iteration = 0;
my $run_id = time();

say("run_id = $run_id");

if ($input_file =~ m{$basedir}sio) {
	die "The input file is inside the basedir and will be overwritten by MTR. Please move it out of the way";
}

my $simplifier = GenTest::Simplifier::Mysqltest->new(
	oracle => sub {
		my $oracle_mysqltest = shift;
		$iteration++;

		chdir($basedir.'/mysql-test');
		chdir($basedir.'\mysql-test');

		my $tmpfile = $run_id.'-'.$iteration.'.test';

		open (ORACLE_MYSQLTEST, ">t/$tmpfile") or die "Unable to open $tmpfile: $!";
		print ORACLE_MYSQLTEST "--source include/master-slave.inc\n" if $replication;
                print ORACLE_MYSQLTEST $oracle_mysqltest;
		print ORACLE_MYSQLTEST "--sync_slave_with_master\n" if $replication;
		print ORACLE_MYSQLTEST $oracle_mysqltest;
		close ORACLE_MYSQLTEST;

		my $mysqltest_cmd = "perl mysql-test-run.pl ".join(' ', @mtr_options)." t/$tmpfile 2>&1";

		my $mysqltest_output = `$mysqltest_cmd`;

		print $mysqltest_output if $iteration == 1;

		#
		# We declare the test to have failed properly only if the desired message is present in the output
		# and it is not a result of an error that caused part of the test, including the --die construct, to
		# be printed to stdout.
		#

		if (
			($mysqltest_output =~ m{$expected_mtr_output}sio) &&
			($mysqltest_output !~ m{--die}sio)
		) {
			say("Issue repeatable with $tmpfile");
			return ORACLE_ISSUE_STILL_REPEATABLE;
		} else {
			say("Issue not repeatable with $tmpfile.");
			unlink('t/'.$tmpfile) if $iteration > 1;
			return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
		}
	}
);

my $simplified_mysqltest;

if ($input_file =~ m{\.csv$}sgio) {
	say("Treating $input_file as a CSV file");
	$simplified_mysqltest = $simplifier->simplifyFromCSV($input_file);
} elsif ($input_file =~ m{\.test$}sgio) {
	say("Treating $input_file as a mysqltest file");
	open (MYSQLTEST_FILE , $input_file) or die "Unable to open $input_file as a .test file: $!";
	read (MYSQLTEST_FILE , my $initial_mysqltest, -s $input_file);
	close (MYSQLTEST_FILE);
	$simplified_mysqltest = $simplifier->simplify($initial_mysqltest);
}

if (defined $simplified_mysqltest) {
	print "Simplified mysqltest:\n\n$simplified_mysqltest.\n";
	exit (STATUS_OK);
} else {
	print "Unable to simplify $input_file.\n";
	exit (STATUS_ENVIRONMENT_FAILURE);
}
