# Copyright (C) 2008-2009 Sun Microsystems, Inc. All rights reserved.
# Use is subject to license terms.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301
# USA

use strict;
use lib 'lib';
use lib "$ENV{RQG_HOME}/lib";
use List::Util 'shuffle';
use GenTest::Random;
use GenTest::Constants;
use Getopt::Long;
use Data::Dumper;

my ($config_file, $basedir, $vardir, $trials, $duration, $grammar, $gendata, 
    $seed, $testname, $xml_output, $report_xml_tt, $report_xml_tt_type,
    $report_xml_tt_dest, $no_mask);

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
	'no-mask' => \$no_mask,
	'grammar=s' => \$grammar,
	'gendata=s' => \$gendata,
	'testname=s' => \$testname,
	'xml-output=s' => \$xml_output,
	'report-xml-tt' => \$report_xml_tt,
	'report-xml-tt-type=s' => \$report_xml_tt_type,
	'report-xml-tt-dest=s' => \$report_xml_tt_dest,
);

my $prng = GenTest::Random->new(
	seed => $seed eq 'time' ? time() : $seed
);

open(CONF, $config_file) or die "unable to open config file '$config_file': $!";
read(CONF, my $config_text, -s $config_file);
eval ($config_text);
die "Unable to load $config_file: $@" if $@;

mkdir($vardir);

my $comb_count = $#$combinations + 1;

foreach my $trial_id (1..$trials) {
	my @comb;
	foreach my $comb_id (0..($comb_count-1)) {
		$comb[$comb_id] = $combinations->[$comb_id]->[$prng->uint16(0, $#{$combinations->[$comb_id]})];
	}

	my $comb_str = join(' ', @comb);

	my $mask = $prng->uint16(0, 65535);

	my $command = "
		perl ".(defined $ENV{RQG_HOME} ? $ENV{RQG_HOME}."/" : "" )."runall.pl $comb_str
		--mask=$mask
		--queries=100000000
	";

	$command .= " --mask=$mask" if not defined $no_mask;
	$command .= " --duration=$duration" if $duration ne '';
	$command .= " --basedir=$basedir " if $basedir ne '';
	$command .= " --gendata=$gendata " if $gendata ne '';
	$command .= " --grammar=$grammar " if $grammar ne '';
	$command .= " --seed=$seed " if $seed ne '';
	$command .= " --testname=$testname " if $testname ne '';
	$command .= " --xml-output=$xml_output " if $xml_output ne '';
	$command .= " --report-xml-tt" if defined $report_xml_tt;
	$command .= " --report-xml-tt-type=$report_xml_tt_type " if $report_xml_tt_type ne '';
	$command .= " --report-xml-tt-dest=$report_xml_tt_dest " if $report_xml_tt_dest ne '';

	$command .= " --vardir=$vardir/current " if $command !~ m{--mem}sio && $vardir ne '';
	$command =~ s{[\t\r\n]}{ }sgio;
	$command .= " 2>&1 | tee $vardir/trial".$trial_id.'.log';

	$commands[$trial_id] = $command;

	$command =~ s{"}{\\"}sgio;
	$command = 'bash -c "set -o pipefail; '.$command.'"';

	print localtime()." [$$] $command\n";
	my $result = system($command);
	$result = $result >> 8;
	print localtime()." [$$] runall.pl exited with exit status $result. \n";
	exit($result) if ($result == STATUS_ENVIRONMENT_FAILURE) || ($result == 255);

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
foreach my $string ('text=', 'bugcheck', 'Error: assertion', 'mysqld got signal', 'Received signal', 'exception') {
	system("grep -i '$string' $vardir/trial*log");
} 

print localtime()." [$$] $0 will exit with exit status $max_result\n";
exit($max_result);
