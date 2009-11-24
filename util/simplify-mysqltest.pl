use strict;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use Getopt::Long;

use GenTest;
use GenTest::Properties;
use GenTest::Constants;
use GenTest::Simplifier::Mysqltest;

my $options = {};
GetOptions($options, 
           'config=s',
           'input_file=s',
           'basedir=s',
           'expected_mr_output=s',
           'verbose!');
my $config = GenTest::Properties->new(
    options => $options,
    defaults => {
        mtr_options => {
            'skip-ndbcluster' => undef,
            'record' => undef,
            'mem' => undef,
            'no-check-testcases' => undef},
        replication => 0, # Set to 1 to turn on --source
                          # include/master-slave.inc and
                          # --sync_slave_with_master
    }
    );

$config->printProps;

# End of user-configurable section

my $iteration = 0;
my $run_id = time();

say("run_id = $run_id");

if ($config->input_file =~ m{$config->basedir}sio) {
	croak "The input file is inside the basedir and will be overwritten by MTR. Please move it out of the way";
}

my $simplifier = GenTest::Simplifier::Mysqltest->new(
	oracle => sub {
		my $oracle_mysqltest = shift;
		$iteration++;
        
		chdir($config->basedir.'/mysql-test');
		chdir($config->basedir.'\mysql-test');

		my $tmpfile = $run_id.'-'.$iteration.'.test';
        
		open (ORACLE_MYSQLTEST, ">t/$tmpfile") or croak "Unable to open $tmpfile: $!";
		print ORACLE_MYSQLTEST "--source include/master-slave.inc\n" if $config->replication;
        print ORACLE_MYSQLTEST $oracle_mysqltest;
		print ORACLE_MYSQLTEST "--sync_slave_with_master\n" if $config->replication;
		print ORACLE_MYSQLTEST $oracle_mysqltest;
		close ORACLE_MYSQLTEST;

		my $mysqltest_cmd = 
            "perl mysql-test-run.pl ". $config->genOpt('--', 'mtr_options').
            " t/$tmpfile 2>&1";

		my $mysqltest_output = `$mysqltest_cmd`;

		say $mysqltest_output if $iteration == 1;

		#
		# We declare the test to have failed properly only if the
		# desired message is present in the output and it is not a
		# result of an error that caused part of the test, including
		# the --croak construct, to be printed to stdout.
		#

		if (
			($mysqltest_output =~ m{$config->expected_mtr_output}sio) &&
			($mysqltest_output !~ m{--croak}sio)
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

if ($config->input_file =~ m{\.csv$}sgio) {
	say("Treating $config->input_file as a CSV file");
	$simplified_mysqltest = $simplifier->simplifyFromCSV($config->input_file);
} elsif ($config->input_file =~ m{\.test$}sgio) {
	say("Treating $config->input_file as a mysqltest file");
	open (MYSQLTEST_FILE , $config->input_file) or croak "Unable to open $config->input_file as a .test file: $!";
	read (MYSQLTEST_FILE , my $initial_mysqltest, -s $config->input_file);
	close (MYSQLTEST_FILE);
	$simplified_mysqltest = $simplifier->simplify($initial_mysqltest);
}

if (defined $simplified_mysqltest) {
	say "Simplified mysqltest:\n\n$simplified_mysqltest.\n";
	exit (STATUS_OK);
} else {
	say "Unable to simplify $config->input_file.\n";
	exit (STATUS_ENVIRONMENT_FAILURE);
}
