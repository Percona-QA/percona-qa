use strict;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use List::Util 'shuffle';
use GenTest::Random;
use Getopt::Long;
use Data::Dumper;

my ($config_file, $basedir, $vardir, $trials, $duration, $grammar, $gendata);
my $seed = 1;
my $combinations;
my %results;
my @commands;
my $max_result = 0;

my $opt_result = GetOptions(
        'config=s' => \$config_file,
	'basedir=s' => \$basedir,
	'vardir=s' => \$vardir,
	'trials=i' => \$trials,
	'duration=i' => \$duration,
	'seed=s' => \$seed,
	'grammar=s' => \$grammar,
	'gendata=s' => \$gendata
);

my $prng = GenTest::Random->new(
	seed => $seed eq 'time' ? time() : $seed
);

open(CONF, $config_file) or die "unable to open config file '$config_file': $!";
read(CONF, my $config_text, -s $config_file);
eval ($config_text);
die "Unable to load $config_file: $@" if $@;

my $comb_count = $#$combinations + 1;

foreach my $trial_id (1..$trials) {
	my @comb;
	foreach my $comb_id (0..($comb_count-1)) {
		$comb[$comb_id] = $combinations->[$comb_id]->[$prng->uint16(0, $#{$combinations->[$comb_id]})];
	}

	my $comb_str = join(' ', @comb);

	my $mask = $prng->uint16(0, 65535);

	my $command = "
		perl runall.pl $comb_str
		--mask=$mask
		--queries=100000000
	";

	$command .= " --duration=$duration" if $duration ne '';
	$command .= " --basedir=$basedir " if $basedir ne '';
	$command .= " --gendata=$gendata " if $gendata ne '';
	$command .= " --grammar=$grammar " if $grammar ne '';
	$command .= " --seed=$seed " if $seed ne '';

	$command .= " --vardir=$vardir/current " if $command !~ m{--mem}sio && $vardir ne '';
	$command =~ s{[\t\r\n]}{ }sgio;
	$command .= " 2>&1 | tee $vardir/trial".$trial_id.'.log';

	$commands[$trial_id] = $command;

	$command =~ s{"}{\\"}sgio;
	$command = 'bash -c "set -o pipefail; '.$command.'"';

	print localtime()." [$$] $command\n";
	my $result = system($command);
	print localtime()." [$$] runall.pl exited with exit status ".($result >> 8)."\n";

	if ($result > 0) {
		$max_result = $result >> 8 if ($result >> 8) > $max_result;
		print localtime()." [$$] Copying vardir to $vardir/vardir".$trial_id."\n";
		if ($command =~ m{--mem}) {
			system("cp -r /dev/shm/var $vardir/vardir".$trial_id);
		} else {
			system("cp -r $vardir/current $vardir/vardir".$trial_id);
		}
		open(OUT, ">$vardir/vardir".$trial_id."/command");
		print OUT $command;
		close(OUT);
	}
	$results{$result >> 8}++;
}

print localtime()." [$$] Summary of various interesting strings from the logs:\n";
print Dumper \%results;
foreach my $string ('text=', 'bugcheck', 'Error: assertion', 'mysqld got signal', 'exception') {
	system("grep -i '$string' $vardir/trial*log");
} 

print localtime()." [$$] $0 will exit with exit status $max_result\n";
exit($max_result);
