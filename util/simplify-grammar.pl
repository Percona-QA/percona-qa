use strict;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use GenTest::Simplifier::Grammar;
use Time::HiRes;

# 
# This script is used to simplify grammar files to the smallest form that will still reproduce the desired outcome
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
	'--basedir=/build/bzr/mysql-next-bugfixing',
	'--gendata=conf/WL5004_data.zz --threads=40 --rpl_mode=row --queries=10K --duration=40 --reporter=Deadlock,Shutdown'
);

my $initial_grammar_file = 'conf/WL5004_sql.yy';

# Status codes are described in lib/GenTest/Constants.pm
# STATUS_ANY_ERROR means that any RQG error would cause the simplification to continue,
# e.g. both deadlocks and crashes will be considered together

my @desired_status_codes = (STATUS_REPLICATION_FAILURE);

# This is the number of times the oracle() will run the RQG in order to get to the
# desired error code. If the error is sporadic, several runs may be required to know
# if the bug is still present in the simplified grammar or not.

my $trials = 1;

# Set $grammar_flags to GRAMMAR_FLAG_COMPACT_RULES so that rules such as rule: a | a | a | a | a | a | b
# are compressed to rule: a | b before simplification. This will speed up the process as each instance of
# "a" will not be removed separately until they are all gone.

my $grammar_flags = GRAMMAR_FLAG_COMPACT_RULES;

# End of user-modifiable settings

my $run_id = time();

say("The ID of this run is $run_id.");

open(INITIAL_GRAMMAR, $initial_grammar_file) or die "Umable to open '$initial_grammar_file': $!";;
read(INITIAL_GRAMMAR, my $initial_grammar , -s $initial_grammar_file);
close(INITIAL_GRAMMAR);

my $iteration;

my $simplifier = GenTest::Simplifier::Grammar->new(
	grammar_flags => $grammar_flags,
	oracle => sub {

		my $oracle_grammar = shift;

		foreach my $trial (1..$trials) {
			$iteration++;
			say("run_id = $run_id; iteration = $iteration; trial = $trial");

			my $tmpfile = tmpdir().$run_id.'-'.$iteration.'-'.$trial.'.yy';
			my $logfile = tmpdir().$run_id.'-'.$iteration.'-'.$trial.'.log';
			my $vardir = tmpdir().$run_id.'-'.$iteration.'-'.$trial.'-var';
			open (GRAMMAR, ">$tmpfile") or die "unable to create $tmpfile: $!";
			print GRAMMAR $oracle_grammar;
			close (GRAMMAR);

			my $start_time = Time::HiRes::time();

			mkdir ($vardir);
			my $rqg_status = system("perl runall.pl ".join(' ', @rqg_options)." --grammar=$tmpfile --vardir=$vardir 2>&1 >$logfile");
			$rqg_status = $rqg_status >> 8;

			my $end_time = Time::HiRes::time();
			my $duration = $end_time - $start_time;

			say("rqg_status = $rqg_status; duration = $duration");

			return ORACLE_ISSUE_NO_LONGER_REPEATABLE if $rqg_status == STATUS_ENVIRONMENT_FAILURE;
			
			foreach my $desired_status_code (@desired_status_codes) {
				if (
					($rqg_status == $desired_status_code) ||
					(($rqg_status != 0) && ($desired_status_code == STATUS_ANY_ERROR))
				) {
					return ORACLE_ISSUE_STILL_REPEATABLE;
				}
			}
		}
		return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
	}
);

my $simplified_grammar = $simplifier->simplify($initial_grammar);

print "Simplified grammar:\n\n$simplified_grammar;\n\n" if defined $simplified_grammar;
