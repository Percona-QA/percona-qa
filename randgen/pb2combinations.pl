use strict;
use Cwd;
use File::Basename;
use POSIX;
use Sys::Hostname;

my ($basedir, $vardir, $tree, $test) = @ARGV;

print("==================== Starting $0 ====================\n");
# Print MTR-style output saying which test suite/mode this is for PB2 reporting.
# So far we only support running one test at a time.
print("##############################################################################\n");
print("# $test\n");
print("##############################################################################\n");

# Autoflush output buffers (needed when using POSIX::_exit())
$| = 1;

chdir('randgen');

#print localtime()." [$$] Information on Random Query Generator version:\n";
#system("bzr parent");
#system("bzr version-info");

my $cwd = cwd();

# Location of grammars and other test configuration files.
# Will use env variable RQG_CONF is set.
# Default is currently "conf" while using legacy setup.
# If not absolute path, it is relative to cwd at run time, which is the randgen directory.
my $conf = $ENV{RQG_CONF};
$conf = 'conf' if not defined $conf;

print("***** Information on the host system: *****\n");
print(" - Local time  : ".localtime()."\n");
print(" - Hostname    : ".hostname()."\n");
print(" - PID         : $$\n");
print(" - Working dir : ".cwd()."\n");
print(" - PATH        : ".$ENV{PATH}."\n");
print(" - Script arguments:\n");
print("       basedir = $basedir\n");
print("       vardir  = $vardir\n");
print("       tree    = $tree\n");
print("       test    = $test\n");
print("\n");
print("***** Information on Random Query Generator version (bzr): *****\n");
system("bzr info");
system("bzr version-info");
print("\n");

mkdir($vardir);

my $command;

if ($test =~ m{falcon_combinations_simple}io ) {
	$command = '
		--grammar='.$conf.'/combinations.yy
		--gendata='.$conf.'/combinations.zz
		--config='.$conf.'/falcon_simple.cc
		--duration=900
		--trials=4
		--seed=time
	';
} elsif ($test =~ m{falcon_combinations_transactions}io ) {
	$command = '
		--grammar='.$conf.'/transactions-flat.yy
		--gendata='.$conf.'/transactions.zz
		--config='.$conf.'/falcon_simple.cc
		--duration=900
		--trials=4
		--seed=time
	';
} elsif ($test =~ m{innodb_combinations_simple}io ) {
	$command = '
		--grammar='.$conf.'/combinations.yy
		--gendata='.$conf.'/combinations.zz
		--config='.$conf.'/innodb_simple.cc
		--duration=1800
		--trials=4
		--seed=time
	';
} elsif ($test =~ m{innodb_combinations_stress}io ) {
	$command = '
		--grammar='.$conf.'/engine_stress.yy
		--gendata='.$conf.'/engine_stress.zz
		--config='.$conf.'/innodb_simple.cc
		--duration=600
		--trials=4
		--seed=time
	';
} elsif ($test =~ m{falcon_combinations_varchar}io ) {
	$command = '
		--grammar='.$conf.'/varchar.yy
		--gendata='.$conf.'/varchar.zz
		--config='.$conf.'/falcon_varchar.cc
		--duration=900
		--trials=4
		--seed=time
	';
} else {
	die("unknown combinations test $test");
}

# Assuming Unix for now (using tail).

$command = "perl combinations.pl --basedir=\"$basedir\" --vardir=\"$vardir\" ".$command;
# redirect output to log file to avoid sending huge amount of output to PB2
my $log_file = $vardir.'/pb2comb_'.$test.'.out';
$command = $command." > $log_file 2>&1";
$command =~ s{[\r\n\t]}{ }sgio;

print localtime()." [$$] Executing command: $command\n";
my $command_result = system($command);
# shift result code to the right to obtain the code returned from the called script
my $command_result_shifted = ($command_result >> 8);
print localtime()." [$$] combinations.pl exited with exit status ".$command_result_shifted."\n";


# Report test result in an MTR fashion so that PB2 will see it and add to
# xref database etc.
# Format: TESTSUITE.TESTCASE 'TESTMODE' [ RESULT ]
# Example: ndb.ndb_dd_alter 'InnoDB plugin'     [ fail ]
# Not using TESTMODE for now.
my $test_suite_name = 'serverqa';
my $full_test_name = $test_suite_name.'.'.$test;
# keep test statuses more or less vertically aligned (if more than one)
while (length $full_test_name < 40)
{
	$full_test_name = $full_test_name.' ';
}

if ($command_result_shifted > 0) {
	# test failed
	print("------------------------------------------------------------------------\n");
	print($full_test_name." [ fail ]\n");
} else {
	print($full_test_name." [ pass ]\n");
}
# Print first and last part of log file (assuming it is longer than 100-200 lines).
# This is hopefully just a temporary hack solution...
# Caveats: If the file is shorter than 100 lines, the output will be duplicated on std out.
#          If the file is between 100 and 200 lines, some of the output will be duplicated on std out.
#          Using 'head' and 'tail', so probably won't work on windows (unless required gnu utils are installed)
#          Hanged proceses not especially handled.
#          etc.
my $lines = 100;
print("----->  Printing first $lines and last $lines lines (may overlap) from test output...\n");
print('----->  See log file '.basename($log_file)." for full output.\n\n");
system("head -$lines $log_file");
print("\n.\n.\n.\n.\n.\n(...)\n.\n.\n.\n.\n.\n\n");
system("tail -$lines $log_file");
print("\n");
print localtime()." [$$] $0 will exit with exit status ".$command_result_shifted."\n";
POSIX::_exit ($command_result_shifted);
