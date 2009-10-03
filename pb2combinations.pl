use strict;
use POSIX;
use Cwd;

my ($basedir, $vardir, $tree, $test) = @ARGV;

chdir('gentest/mysql-test/gentest');

print localtime()." [$$] Information on the host system:\n";
system("uname -a");
system("hostname");

#print localtime()." [$$] Information on Random Query Generator version:\n";
#system("bzr parent");
#system("bzr version-info");

my $cwd = cwd();

mkdir($vardir);

my $command;

if ($test =~ m{falcon_combinations_simple}io ) {
	$command = '
		--grammar=conf/combinations.yy
		--gendata=conf/combinations.zz
		--config=conf/falcon_simple.cc
		--duration=900
		--trials=100
		--seed=time
	';
} elsif ($test =~ m{falcon_combinations_transactions}io ) {
	$command = '
		--grammar=conf/transactions-flat.yy
		--gendata=conf/transactions.zz
		--config=conf/falcon_simple.cc
		--duration=900
		--trials=100
		--seed=time
	';
} elsif ($test =~ m{innodb_combinations_simple}io ) {
	$command = '
		--grammar=conf/combinations.yy
		--gendata=conf/combinations.zz
		--config=conf/innodb_simple.cc
		--duration=1800
		--trials=100
		--seed=time
	';
} elsif ($test =~ m{innodb_combinations_stress}io ) {
	$command = '
		--grammar=conf/engine_stress.yy
		--gendata=conf/engine_stress.zz
		--config=conf/innodb_simple.cc
		--duration=600
		--trials=100
		--seed=time
	';
} elsif ($test =~ m{falcon_combinations_varchar}io ) {
	$command = '
		--grammar=conf/varchar.yy
		--gendata=conf/varchar.zz
		--config=conf/falcon_varchar.cc
		--duration=900
		--trials=100
		--seed=time
	';
} else {
	die("unknown combinations test $test");
}

$command = "perl combinations.pl --basedir=\"$basedir\" --vardir=\"$vardir\" ".$command;
$command =~ s{[\r\n\t]}{ }sgio;

my $command_result = system($command);
print localtime()." [$$] combinations.pl exited with exit status ".($command_result >> 8)."\n";
print localtime()." [$$] $0 will exit with exit status ".($command_result >> 8)."\n";
POSIX::_exit ($command_result >> 8);
