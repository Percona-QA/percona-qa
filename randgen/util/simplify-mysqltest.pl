use strict;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use File::Compare;
use File::Copy;
use Getopt::Long;

use GenTest;
use GenTest::Properties;
use GenTest::Constants;
use GenTest::Simplifier::Mysqltest;


# NOTE: oracle function behaves differently if basedir2 is specified in addition
#       to basedir. In this case expected_mtr_output is ignored, and result
#       comparison between servers is performed instead.

my $options = {};
my $o = GetOptions($options, 
           'config=s',
           'input_file=s',
           'basedir=s',
           'basedir2=s',
           'expected_mtr_output=s',
           'verbose!',
           'mtr_options=s%',
           'mysqld=s%',
           'replication!');
my $config = GenTest::Properties->new(
    options => $options,
    legal => [
        'config',
        'input_file',
        'basedir',
        'basedir2',
        'expected_mtr_output',
        'mtr_options',
        'vebose',
        'replication',
        'mysqld'
    ],
    required => [
        'basedir',
        'input_file',
        'mtr_options'],
    defaults => {
        replication => 0, # Set to 1 to turn on --source
                          # include/master-slave.inc and
                          # --sync_slave_with_master
    }
    );

$config->printHelp if not $o;
$config->printProps;

# End of user-configurable section

my $iteration = 0;
my $run_id = time();

say("run_id = $run_id");

my $simplifier = GenTest::Simplifier::Mysqltest->new(
    oracle => sub {
        my $oracle_mysqltest = shift;
        $iteration++;
        
        chdir($config->basedir.'/mysql-test'); # assume forward slash works

        my $tmpfile_base_name = $run_id.'-'.$iteration; # we need this for both test- and result file name
        my $tmpfile = $tmpfile_base_name.'.test';      # test file of this iteration
        
        open (ORACLE_MYSQLTEST, ">t/$tmpfile") or croak "Unable to open $tmpfile: $!";
        print ORACLE_MYSQLTEST "--source include/master-slave.inc\n" if $config->replication;
        print ORACLE_MYSQLTEST $oracle_mysqltest;
        print ORACLE_MYSQLTEST "--sync_slave_with_master\n" if $config->replication;
        close ORACLE_MYSQLTEST;

        my $mysqldopt = $config->genOpt('--mysqld=--', 'mysqld');

        my $mysqltest_cmd = 
            "perl mysql-test-run.pl $mysqldopt ". $config->genOpt('--', 'mtr_options').
            " t/$tmpfile 2>&1";

        my $mysqltest_output = `$mysqltest_cmd`;
        say $mysqltest_output if $iteration == 1;
        
        ########################################################################
        # Start of comparison mode (two basedirs)
        ########################################################################
        
        if (defined $config->basedir2) {
            if ($iteration == 1) {
                say ('Two basedirs specified. Will compare outputs instead of looking for expected output.');
                say ('Server A: '.$config->basedir);
                say ('Server B: '.$config->basedir2);
                # NOTE: --record MTR option is required. TODO: Check for this?
            }
            
            #
            # Run the test against basedir2 and compare results against the previous run.
            #
            
            chdir($config->basedir2.'/mysql-test');
            
            # working dir is now for Server B, so we need full path to Server A's files for later
            my $tmpfile_full_path = $config->basedir.'/mysql-test/t/'.$tmpfile;
            my $resultfile_full_path = $config->basedir.'/mysql-test/r/'.$tmpfile_base_name.'.result';
                
            # tests/results for Server B include "-b" in the filename
            my $tmpfile2_base_name = $run_id.'-'.$iteration.'-b';
            my $tmpfile2 = $tmpfile2_base_name.'.test';
            my $tmpfile2_full_path = $config->basedir2.'/mysql-test/t/'.$tmpfile2;
            my $resultfile2_full_path = $config->basedir2.'/mysql-test/r/'.$tmpfile2_base_name.'.result';
            
            # Copy test file to server B
            copy($tmpfile_full_path, $tmpfile2_full_path) or croak("Unable to copy test file $tmpfile to $tmpfile2");
            
            my $mysqltest_cmd2 = 
                "perl mysql-test-run.pl $mysqldopt ". $config->genOpt('--', 'mtr_options').
                " $tmpfile2 2>&1";

            # Run the test against server B
            # we don't really use this output for anything right now
            my $mysqltest_output2 = `$mysqltest_cmd2`;
            #say $mysqltest_output2 if $iteration == 1;
            
            
            # Compare the two results
            # We declare the tests to have failed properly only if the results
            # from the two test runs differ.
            # (We ignore expected_mtr_output in this mode)
            my $compare_result = compare($resultfile_full_path, $resultfile2_full_path);
            if ( $compare_result == 0) {
                # no diff
                say('Issue not repeatable (results were equal) with test '.$tmpfile_base_name);
                unlink($tmpfile_full_path) if $iteration > 1; # deletes test for Server A
                unlink($tmpfile2_full_path) if $iteration > 1; # deletes test for Server B
                unlink($resultfile_full_path) if $iteration > 1; # deletes result for Server A
                unlink($resultfile2_full_path) if $iteration > 1; # deletes result for Server B
                return ORACLE_ISSUE_NO_LONGER_REPEATABLE;
            } elsif ($compare_result > 0) {
                # diff
                say("Issue is repeatable (results differ) with test $tmpfile_base_name");
                return ORACLE_ISSUE_STILL_REPEATABLE;
            } else {
                # error ($compare_result < 0)
                say("\nError ($compare_result) comparing result files for test $tmpfile_base_name");
                if (! -e $resultfile_full_path) {
                    say("Test output was:");
                    say $mysqltest_output;
                    # TODO: No result file may mean that we tried an invalid query
                    #       Try comparing .reject files in this case?
                    croak("Resultfile  $resultfile_full_path not found");
                } elsif (! -e $resultfile_full_path) {
                    say("Test output was:");
                    say $mysqltest_output2;
                    croak("Resultfile2 $resultfile2_full_path not found");
                }
            }

        ########################################################################
        # End of comparison mode (two basedirs)
        ########################################################################
            
        } else {
            # Only one basedir specified - retain old behavior (look for expected output).

            #
            # We declare the test to have failed properly only if the
            # desired message is present in the output and it is not a
            # result of an error that caused part of the test, including
            # the --croak construct, to be printed to stdout.
            #
    
            my $expected_mtr_output = $config->expected_mtr_output;
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
    }
);

my $simplified_mysqltest;

## Copy input file
if (-f $config->input_file){
    $config->input_file =~ m/\.([a-z]+$)/i;
    my $extension = $1;
    my $input_file_copy = $config->basedir."/mysql-test/t/".$run_id."-0.".$extension;
    system("cp ".$config->input_file." ".$input_file_copy);
    
    if (lc($extension) eq 'csv') {
        say("Treating ".$config->input_file." as a CSV file");
        $simplified_mysqltest = $simplifier->simplifyFromCSV($input_file_copy);
    } elsif (lc($extension) eq 'test') {
        say("Treating ".$config->input_file." as a mysqltest file");
        open (MYSQLTEST_FILE , $input_file_copy) or croak "Unable to open ".$input_file_copy." as a .test file: $!";
        read (MYSQLTEST_FILE , my $initial_mysqltest, -s $input_file_copy);
        close (MYSQLTEST_FILE);
        $simplified_mysqltest = $simplifier->simplify($initial_mysqltest);
    } else {
        carp "Unknown file type for ".$config->input_file;
    }

    if (defined $simplified_mysqltest) {
        say "Simplified mysqltest:\n\n$simplified_mysqltest.\n";
        exit (STATUS_OK);
    } else {
        say "Unable to simplify ". $config->input_file.".\n";
        exit (STATUS_ENVIRONMENT_FAILURE);
    }
} else {
    croak "Can't find ".$config->input_file;
}
##

