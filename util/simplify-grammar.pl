use strict;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest;
use GenTest::Constants;
use GenTest::Simplifier::Grammar;
use Time::HiRes;

# 
# This script is used to simplify grammar files to the smallest form that will still reproduce the problem
# For the purpose, the GenTest::Simplifier::Grammar module provides progressively simple grammars, and we
# define an oracle() function that runs those grammars with the RQG and reports if the RQG returns the desired
# status code (usually something like STATUS_SERVER_CRASHED
#
# For more information, please see:
#
# http://forge.mysql.com/wiki/RandomQueryGeneratorSimplification
#

#
# Please modify those settings to fit your environment before you run this script
#

my @rqg_options =( 
	'--mem',
	'--threads=1',
	'--basedir=/path/to/mysql/basedir',
	'--mysqld=--innodb-lock-wait-timeout=1',
	'--mysqld=--table-lock-wait-timeout=1',
	'--reporters=Deadlock,ErrorLog',
	'--validators=',
	'--queries=10000',
	'--duration=90'
);

my $initial_grammar_file = 'conf/example.yy';

# Status codes are described in lib/GenTest/Constants.pm

my $expected_status_code = STATUS_SERVER_CRASHED;

# This is the number of times the oracle() will run the RQG in order to get to the
# desired error code. If the error is sporadic, several runs may be required to know
# if the bug is still present in the simplified grammar or not.

my $trials = 1;

# End of user-modifiable settings

my $run_id = time();

say("The ID of this run is $run_id.");

open(INITIAL_GRAMMAR, $initial_grammar_file);
read(INITIAL_GRAMMAR, my $initial_grammar , -s $initial_grammar_file);
close(INITIAL_GRAMMAR);

my $iteration;

my $simplifier = GenTest::Simplifier::Grammar->new(
	oracle => sub {

		my $oracle_grammar = shift;

		foreach my $trial (1..$trials) {
			$iteration++;
			say("run_id = $run_id; iteration = $iteration; trial = $trial");

			my $tmpfile = tmpdir().$run_id.'-'.$iteration.'-'.$trial.'.yy';
			my $logfile = tmpdir().$run_id.'-'.$iteration.'-'.$trial.'.log';
			open (GRAMMAR, ">$tmpfile") or die "unable to create $tmpfile: $!";
			print GRAMMAR $oracle_grammar;
			close (GRAMMAR);

			my $start_time = Time::HiRes::time();

			my $rqg_status = system("perl runall.pl ".join(' ', @rqg_options)." --grammar=$tmpfile 2>&1 >$logfile");
			$rqg_status = $rqg_status >> 8;

			my $end_time = Time::HiRes::time();
			my $duration = $end_time - $start_time;

			say("rqg_status = $rqg_status; duration = $duration");

			return 0 if $rqg_status == STATUS_ENVIRONMENT_FAILURE;

			if ($rqg_status == $expected_status_code) {
				return 1;
			} 
		}
		return 0;
	}
);

my $simplified_grammar = $simplifier->simplify($initial_grammar);

print "Simplified grammar:\n\n$simplified_grammar;\n\n";
