## Hunting for bugs.
## 
## Repeated runs of runall with different seeds.
## Will run repeatedly trial times.
## If expected_outputs (of which there may be several) is specified it
## will report if is found 
## If desired_status_codes it will report if one is found.
## if stop_on_match it will stop if there is a match (one of the
## status codes, all of the exepcted outputs).

use strict;
use lib 'lib';
use lib '../lib';
use DBI;
use Carp;
use Getopt::Long;
use Data::Dumper;

use GenTest;
use GenTest::Constants;
use GenTest::Grammar;
use GenTest::Properties;
use GenTest::Simplifier::Grammar;
use Time::HiRes;

my $options = {};
GetOptions($options, 
           'config=s',
           'grammar=s',
           'trials=i',
           'initial_seed=i',
           'storage_prefix=s',
           'expected_outputs=s@',
           'desired_status_codes=s@',
           'rqg_options=s%',
           'basedir=s',
           'vardir_prefix=s',
           'mysqld=s%',
           'stop_on_match!');
my $config = GenTest::Properties->new(
    options => $options,
    legal => ['desired_status_codes',
              'expected_outputs',
              'grammar',
              'trials',
              'initial_seed',
              'search_var_size',
              'rqg_options',
              'vardir_prefix',
              'storage_prefix',
              'stop_on_match',
              'mysqld'],
    required=>['rqg_options',
               'grammar',
               'vardir_prefix',
               'storage_prefix'],
    defaults => {search_var_size=>10000,
                 trials=>1}
    );

# Dump settings
$config->printProps;

## Calculate mysqld and rqg options

my $mysqlopt = $config->genOpt("--mysqld=--",$config->mysqld) 
    if defined $config->mysqld;

my $rqgoptions = $config->genOpt('--', 'rqg_options');

# Determine some runtime parameter, check parameters, ....

my $run_id = time();

say("The ID of this run is $run_id.");

if ( ! -d $config->vardir_prefix ) {
    croak("vardir_prefix '" 
          . $config->vardir_prefix . 
          "' is not an existing directory");
}

my $vardir = $config->vardir_prefix . '/var_' . $run_id;
mkdir ($vardir);
push my @mtr_options, "--vardir=$vardir";

if ( ! -d $config->storage_prefix) {
    croak("storage_prefix '" 
          . $config->storage_prefix . 
          "' is not an existing directory");
}
my $storage = $config->storage_prefix.'/'.$run_id;
say "Storage is $storage";
mkdir ($storage);


my $good_seed = $config->initial_seed;
my $current_seed;
my $current_rqg_log;
foreach my $trial (1..$config->trials) {
    say("###### run_id = $run_id; trial = $trial ######");
    
    $current_seed = $good_seed - 1 + $trial;
    $current_rqg_log = $storage . '/' . $trial . '.log';
    my $errfile = $vardir . '/log/master.err';
    
    my $start_time = Time::HiRes::time();
    
    my $runall =
        "perl runall.pl ". 
        " $rqgoptions $mysqlopt ".
        "--grammar=".$config->grammar." ".
        "--vardir=$vardir ".
        "--seed=$current_seed 2>&1 >$current_rqg_log";
    
    say($runall);
    my $runall_status = system($runall);
    $runall_status = $runall_status >> 8;
    
    my $end_time = Time::HiRes::time();
    my $duration = $end_time - $start_time;
    
    say("runall_status = $runall_status; duration = $duration");
    
    if (defined $config->desired_status_codes) {
        foreach my $desired_status_code (@{$config->desired_status_codes}) {
            if (($runall_status == $desired_status_code) ||
                (($runall_status != 0) && 
                 ($desired_status_code == STATUS_ANY_ERROR))) {
                say ("###### Found status $runall_status ######");
                if (defined $config->expected_outputs) {
                    checkLogForPattern();                
                } else {
                    exit STATUS_OK if $config->stop_on_match;
                }
            }
        }
    } elsif (defined $config->expected_outputs) {
        checkLogForPattern();                
    }
}

#############################

sub checkLogForPattern {
    open (my $my_logfile,'<'.$current_rqg_log) 
        or croak "unable to open $current_rqg_log : $!";

    my @filestats = stat($current_rqg_log);
    my $filesize = $filestats[7];
    my $offset = $filesize - $config->search_var_size;

    ## Ensure the offset is not negative
    $offset = 0 if $offset < 0;  
    read($my_logfile, my $rqgtest_output, 
         $config->search_var_size, 
         $offset );
    close ($my_logfile);
    
    my $match_on_all=1;
    foreach my $expected_output (@{$config->expected_outputs}) {
        if ($rqgtest_output =~ m{$expected_output}sio) {
            say ("###### Found pattern: $expected_output ######");
        } else {
            say ("###### Not found pattern: $expected_output ######");
            $match_on_all = 0;
        }
    }
    exit STATUS_OK if $config->stop_on_match and $match_on_all;
}
