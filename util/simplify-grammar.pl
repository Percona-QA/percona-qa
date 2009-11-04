# use strict; mleich: disabled because of eval `cat $config_file`;
use lib 'lib';
use lib '../lib';
use DBI;

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use GenTest::Simplifier::Grammar;
use Time::HiRes;

# 
# RQG grammar simplification with an oracle() function based on
# 1. RQG exit status codes (-> @desired_status_codes)
# 2. expected RQG protocol output (-> @expected_output)
# Hint: 2. will be not checked if 1. already failed
#
# You need to adjusted parameters to your use case and environment.
# 1. Copy simplify-grammar_template.cfg to for exanple 1.cfg
# 2. Adjust the settings
# 2. perl util/simplify-grammar.pl 1.cfg
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

# Preload user-modifiable settings
#---------------------------------
my $config_file = $ARGV[0];
if ( ! -f $config_file ) {
	say ("config_file ('$config_file') is not a plain file");
	say ("abort");
	exit;
}

my $initial_grammar_file;
my $vardir_prefix;
my $storage;
my @rqg_options;
my @expected_output;
my $trials;
my $initial_seed;
my $grammar_flags;
my $search_var_size;
my @desired_status_codes;

eval `cat $config_file`;

# Determine some runtime parameter, check parameters, ....

my $run_id = time();

say("The ID of this run is $run_id.");

open(INITIAL_GRAMMAR, $initial_grammar_file) or die "Umable to open '$initial_grammar_file': $!";;
read(INITIAL_GRAMMAR, my $initial_grammar , -s $initial_grammar_file);
close(INITIAL_GRAMMAR);

if ( ! -d $vardir_prefix ) {
   say ("vardir_prefix '$vardir_prefix' is not an existing directory");
   say ("abort");
   exit;
}
# Calculate a unique vardir (use $MTR_BUILD_THREAD or $run_id)
my $vardir = $vardir_prefix.'/var_'.$run_id;
mkdir ($vardir);
push @mtr_options, "--vardir=$vardir";

if ( ! -d $storage) {
   say ("storage ('$storage') is not an existing directory");
   say ("abort");
   exit;
}
$storage = $storage.'/'.$run_id;
mkdir ($storage);


# Dump settings
say("SIMPLIFY RQG GRAMMAR BASED ON EXPECTED CONTENT WITHIN SOME FILE");
say("---------------------------------------------------------------");
say("rqg_options           : @rqg_options ");
say("initial_grammar_file  : $initial_grammar_file ");
say("desired_status_codes  : @desired_status_codes ");
say("expected_output       : @expected_output ");
say("trials                : $trials ");
say("initial_seed          : $initial_seed ");
say("storage               : $storage ");
say("vardir_prefix         : $vardir_prefix ");
say("run_id                : $run_id");
say("vardir                : $vardir ");
say("---------------------------------------------------------------");

my $iteration;
my $good_seed = $initial_seed;

my $simplifier = GenTest::Simplifier::Grammar->new(
   grammar_flags => $grammar_flags,
   oracle => sub {

   $iteration++;
   my $oracle_grammar = shift;

   foreach my $trial (1..$trials) {
	  say("run_id = $run_id; iteration = $iteration; trial = $trial");

	  # $current_seed -- The seed value to be used for the next run.
	  # The test results of many grammars are quite sensitive to the seed value.
	  # 1. Run the first trial on the initial grammar with $initial_seed .
	  #	   This should raise the chance that the initial oracle check passes.
	  # 2. Run the first trial on a just simplified grammar with the last successfull
	  #	   seed value. In case the last simplification did remove some random determined
	  #	   we should have a bigger likelihood to reach the expected result.
	  # 3. In case of "threads = 1" it turned out that after a minor simplification the desired
	  #	   bad effect disappeared sometimes on the next run with the same seed value whereas
	  #	   a different seed value was again successful. Therefore we manipulate the seed value.
	  #	   In case of "threads > 1" this manipulation might be not required, but it will not
	  #	   make the conditions worse.
	  my $current_seed = $good_seed - 1 + $trial;

	  # Note(mleich): The grammar used is iteration specific. Don't store per trial.
	  #		 Shouldn't the next command be outside of the loop ?
	  my $current_grammar = $storage.'/'.$iteration.'.yy';
	  my $current_rqg_log = $storage.'/'.$iteration.'-'.$trial.'.log';
	  my $errfile = $vardir.'/log/master.err';
	  open (GRAMMAR, ">$current_grammar") or die "unable to create $current_grammar : $!";
	  print GRAMMAR $oracle_grammar;
	  close (GRAMMAR);

	  my $start_time = Time::HiRes::time();

	  # Note(mleich):
	  #	   In case of "threads = 1" it turned out that after a minor simplification the desired
	  #	   bad effect disappeared sometimes on the next run with the same seed value whereas
	  #	   a different seed value was again successful. Therefore we manipulate the seed value.
	  #	   In case of "threads > 1" this manipulation might be not required, but it will not
	  #	   make the conditions worse.
	  say("perl runall.pl ".join(' ', @rqg_options)." --grammar=$current_grammar --vardir=$vardir --seed=$current_seed 2>&1 >$current_rqg_log");
	  my $rqg_status = system("perl runall.pl ".join(' ', @rqg_options)." --grammar=$current_grammar --vardir=$vardir --seed=$current_seed 2>&1 >$current_rqg_log");

	  $rqg_status = $rqg_status >> 8;

	  my $end_time = Time::HiRes::time();
	  my $duration = $end_time - $start_time;

	  say("rqg_status = $rqg_status; duration = $duration");

	  return ORACLE_ISSUE_NO_LONGER_REPEATABLE if $rqg_status == STATUS_ENVIRONMENT_FAILURE;
   
	  foreach my $desired_status_code (@desired_status_codes) {
		 if (($rqg_status == $desired_status_code) ||
			 (($rqg_status != 0) && ($desired_status_code == STATUS_ANY_ERROR))) {
			# "backtrace" output (independend of server crash or RQG kills the server) is in $current_rqg_log
			open (my $my_logfile,'<'.$current_rqg_log) or die "unable to open $current_rqg_log : $!";
			# If open (above) did not fail than size determination must be successful.
			my @filestats = stat($current_rqg_log);
			my $filesize = $filestats[7];
			my $offset = $filesize - $search_var_size;
			# Of course read fails if $offset < 0
			if ( $offset < 0 ) { $offset = 0 } ;
			read($my_logfile, my $rqgtest_output, $search_var_size, $offset );
			close ($my_logfile);
			# Debug print("$rqgtest_output");

			# Every element of @expected_output must be found in $rqgtest_output.
			my $success = 1;
			foreach my $expected_output (@expected_output) {
			   if ($rqgtest_output =~ m{$expected_output}sio) {
				  say ("###### Found pattern:  $expected_output ######");
			   } else {
				  say ("###### Not found pattern:  $expected_output ######");
				  $success = 0;
				  last;
			   }
			}
			if ( 1 == $success ) {
			   say ("###### SUCCESS with $current_grammar ######");
			   $good_seed = $current_seed;
			   return ORACLE_ISSUE_STILL_REPEATABLE;
			}
		 } # End of check if the output matches given string patterns
	  } # End of loop over @desired_status_codes
   } # End of loop over the trials
   return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
   }
);

my $simplified_grammar = $simplifier->simplify($initial_grammar);

print "Simplified grammar:\n\n$simplified_grammar;\n\n" if defined $simplified_grammar;
