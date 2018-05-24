#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Std;
use DBI;

# PXC GTID replication consistency checker

# david.bennett@percona.com - 2015-03-25

# This script is designed to monitor IST replication state between
# PXC wsrep nodes for various SQL instructions.  An example of a
# bug this will test is for is lp1421360.  For reliable results,
# make sure there is no other traffic on the test cluster

my $VERSION='1.1';

### default config section, this can all be specified on command line ###

# first node in array is donor
my @nodes=('localhost');
my $user='root';
my $password='password';
my $database='test';
my $waitforIST=1;  # seconds
my $input='';
my $dsn;

# this is the default SQL instructions that will be read 
my $data=<<'_EOD_';

CREATE TABLE IF NOT EXISTS `my_test_table` (`id` INT PRIMARY KEY AUTO_INCREMENT, `value` CHAR(32)) ENGINE=InnoDB;
INSERT INTO `my_test_table` (`value`) VALUES (md5(rand()));

ANALYZE TABLE `my_test_table`;

OPTIMIZE TABLE `my_test_table`;

REPAIR TABLE `my_test_table`;

DROP TABLE `my_test_table`;

FLUSH DES_KEY_FILE;

FLUSH HOSTS;

FLUSH LOGS;

FLUSH BINARY LOGS;

FLUSH ENGINE LOGS;

FLUSH ERROR LOGS;

FLUSH GENERAL LOGS;

FLUSH RELAY LOGS;

FLUSH SLOW LOGS;

FLUSH PRIVILEGES;

FLUSH QUERY CACHE;

FLUSH STATUS;

FLUSH TABLES;

FLUSH USER_RESOURCES;

FLUSH TABLES WITH READ LOCK;

UNLOCK TABLES;

CREATE TABLE IF NOT EXISTS `my_test_table` (`id` INT PRIMARY KEY AUTO_INCREMENT, `value` CHAR(32)) ENGINE=InnoDB;
INSERT INTO `my_test_table` (`value`) VALUES (md5(rand()));

FLUSH TABLE `my_test_table`;

FLUSH TABLE `my_test_table` WITH READ LOCK;

UNLOCK TABLES;

FLUSH TABLES `my_test_table` FOR EXPORT;

UNLOCK TABLES;

DROP TABLE `my_test_table`;

_EOD_

### subroutines ###

# connect to a host
#
# parameter: {host address}
#
# returns:  {db handle}
#
sub dbconnect {
  my $host=shift(@_);
  return(DBI->connect($dsn.$host, $user, $password,{ 'RaiseError' => 1, 'AutoCommit' => 1 }));
}

# check to make sure node is in GTID mode and synced
#
# parameters: {host address}
#
# returns: 2 on success, !2 on failure
#
sub check_node_status {
  my $ret=0;
  my $dbh=dbconnect(shift(@_));
  my $sth=$dbh->prepare('SELECT @@global.gtid_mode');
  $sth->execute();
  if (my $row=$sth->fetchrow_hashref()) {
    $ret=$row->{'@@global.gtid_mode'} eq 'ON';
  }
  $sth->finish();
  if ($ret) {
    $sth=$dbh->prepare("SHOW GLOBAL STATUS LIKE 'wsrep_local_state'");
    $sth->execute();
    if (my $row=$sth->fetchrow_hashref()) {
      $ret += ($row->{'Value'} == 4);
    }
    $sth->finish();
  }
  $dbh->disconnect();
  return($ret);
}

# get the server uuid
#
# parameters: {db handle}
#
# returns server uuid or 0 on failure
#
sub get_server_uuid {
  my $ret=0;
  my $dbh=shift(@_);
  my $sth=$dbh->prepare('SELECT @@global.server_uuid');
  $sth->execute();
  if (my $row=$sth->fetchrow_hashref()) {
    $ret=$row->{'@@global.server_uuid'};
  }
  $sth->finish();
  return($ret);
}

# get last transaction from a gtid component
#
# parameter: {gtid commponnent either  uuid:# or uuid:#-#}
#
# returns: the latest transaction number (last number) or 0 on error
#
sub get_last_transaction {
  my $gtid=shift(@_);
  my $ret=0;
  if ($gtid =~ m/^([^:]+):([0-9]+)-([0-9]+)/) {
    $ret=$3;
  } elsif ($gtid =~ m/^([^:]+):([0-9]+)/) {
    $ret=$2;
  }
  return($ret);
}

# get latest gtid transaction numbers
#
# parameters: {db handle}
#
# returns (glgtn ref): { 'local' => {#}, 'cluster' => {#}, 'wsrep_last_committed' => {#} }
# 
sub get_latest_gtid_transaction_numbers {
  my $ret={'local'=>0,'cluster'=>0,'wsrep_last_committed'=>0};
  my $dbh=shift(@_);
  # get @@global.gtid_executed
  my $sth=$dbh->prepare('SELECT @@global.gtid_executed');
  $sth->execute();
  my $gtid_executed;
  if (my $row=$sth->fetchrow_hashref()) {
    $gtid_executed=$row->{'@@global.gtid_executed'};
  }
  $sth->finish();
  # parse gtid_executed to get latest local and cluster transaction
  my @gtids=split(/,[\s\r\n]+/m,$gtid_executed);
  if ($#gtids > -1) {
    for my $gtid (@gtids) {
      if (index($gtid,get_server_uuid($dbh)) > -1) {
        $ret->{'local'}=get_last_transaction($gtid);
      } else {
        $ret->{'cluster'}=get_last_transaction($gtid);
      }
    }
  }
  # get wsrep_last_committed  
  $sth=$dbh->prepare("SELECT VARIABLE_VALUE FROM ".
     "INFORMATION_SCHEMA.SESSION_STATUS WHERE " .
     "VARIABLE_NAME = 'wsrep_last_committed'");
  $sth->execute();
  if (my $row=$sth->fetchrow_hashref()) {
    $ret->{'wsrep_last_committed'}=$row->{'VARIABLE_VALUE'};
  }
  $sth->finish();
  return($ret);
}

# report replication consistency to STDOUT
#
# parameters: {host addr}, {glgtn ref before}, {glgtn ref after},
#             {'joinerMode'=>0|1}}
#
# returns: number of errors reported 
#
sub report_replication_consistency {
  my $errs=0;
  my($host,$before,$after,$opts)=@_;
  my $joinerMode=0;
  if (defined $opts) {
    if (defined $opts->{'joinerMode'}) {
      $joinerMode=$opts->{'joinerMode'};
    }
  }
  # check cluster trans
  if ($before->{'cluster'} >= $after->{'cluster'}) {
    print "\tERROR ($host): GTID cluster trans " .
      "before:$before->{'cluster'} " .
      "after:$after->{'cluster'}\n";
    $errs++;
  }
  # check local trans (if not in joiner mode)
  if (!$joinerMode && $before->{'local'} != $after->{'local'}) {
    print "\tERROR ($host): GTID local trans " .
      "before:$before->{'local'} " .
      "after:$after->{'local'}\n";
    $errs++;
  }
  # check wsrep_last_committed
  if ($before->{'wsrep_last_committed'} == $after->{'wsrep_last_committed'}) {
    print "\tERROR ($host): wsrep_committed did not advance: $after->{'wsrep_last_committed'}\n";
    $errs++;
  }
  # report if ok
  if (!$errs) {
    print "\tOK ($host): GTID trans#: $after->{'cluster'} seq: $after->{'wsrep_last_committed'}\n";
  }
  return($errs);
}

# get master status postion
# 
# parameters: {db handle}
#
sub get_master_status_position {
  my $errs=0;
  my($dbh)=@_;
  # get master position
  my $sth=$dbh->prepare('SHOW MASTER STATUS');
  $sth->execute();
  my $position;
  if (my $row=$sth->fetchrow_hashref()) {
    $position=$row->{'Position'};
  }
  $sth->finish();
  # return the position
  return $position;
}

# usage
#
#
sub HELP_MESSAGE {
  print <<"_EOH_";
Usage: [perl] ./pxc-replication-check.pl {options}

This script will check for consistency between the binary log used for async
replication and the WSREP syncronization status to insure that everything
that is written to the binary log is replicated to the WSREP cluster.

Note: In order for this script to run properly,  you must have a cluster
setup and fully Synced with GTID mode on.  

Options:
-h,--help\tPrints this help message and exits.
-i\t\tThe input file to read SQL instructions from.
\t\tBy default, the script reads from embedded \$data
\t\t(value - can be used for standard input)
-n\t\tThe node IP address to communicate with.  If multiple
\t\tnodes are specified separated by commas, the secondary
\t\tnodes will be checked as IST joiners. (default: localhost)
-u\t\tMySQL user account to use (default: root)
-p\t\tMySQL password to use (default: password)
-d\t\tMySQL database to use (default: test)
-w\t\tNumber of seconds to wait for IST (default: 1)
-v,--version\tPrints version and exits.

_EOH_
  exit 1;
}

# version
#
sub VERSION_MESSAGE {
  print "pxc-replication-check.pl Version: $VERSION\n\n";
}

### main program ###

$Getopt::Std::STANDARD_HELP_VERSION=1;
my %options=();
getopts('hvu:p:d:w:n:i:',\%options);

# usage and version

if (defined $options{h}) {
  VERSION_MESSAGE();
  HELP_MESSAGE();
}

if (defined $options{v}) {
  VERSION_MESSAGE();
  exit;
}

# parse arguments

if (defined $options{n}) {
  @nodes=split(',',$options{n});
}

if (defined $options{u}) {
  $user=$options{u};
}

if (defined $options{p}) {
  $password=$options{p};
}

if (defined $options{d}) {
  $database=$options{d};
}

if (defined $options{w}) {
  $waitforIST=$options{w};
}

if (defined $options{i}) {
  $input=$options{i};
  # load input from file into $data
  local $/;
  open SQL_INPUT,"<$input";
  $data = <SQL_INPUT>;
  close SQL_INPUT;
}

# construct DSN

$dsn="DBI:mysql:database=$database;host="; # host appended

# check all nodes are in GTID mode and Synced

for my $host (@nodes) {
  if (check_node_status($host) != 2) {
    die "ERROR ($host): not in GTID mode or not synced\n";
  }
}
print "OK: All nodes are in GTID mode and Synced\n";

# Send SQL data to first host and check replication consistency in between
# nodes
#

my $hostDonor=shift(@nodes);
my $dbhDonor=dbconnect($hostDonor);
my $totalErrors=0;
my $lastMasterPosition=-1;
my $masterPosition=-1;
my $line=0;
for (split /^/, $data) {
  chomp;
  s/^\s+//g;
  s/\s+$//g;
  s/;$//g;
  if ($_ gt '') {
    print ++$line.":".substr($_,0,70).(length($_)>70?'...':'')."\n";
    # record replication position before
    $lastMasterPosition=$masterPosition;
    if ($lastMasterPosition == -1) {
      $lastMasterPosition=get_master_status_position($dbhDonor);
    }
    my $refDonorBefore=get_latest_gtid_transaction_numbers($dbhDonor);
    $dbhDonor->do($_);
    # record replication position after
    $masterPosition=get_master_status_position($dbhDonor);
    my $refDonorAfter=get_latest_gtid_transaction_numbers($dbhDonor);
    if ($masterPosition > $lastMasterPosition) {    
      # report findings
      $totalErrors += report_replication_consistency($hostDonor, $refDonorBefore, $refDonorAfter);
      # check joiners
      sleep($waitforIST);
      for my $hostJoiner (@nodes) {
        my $dbhJoiner=dbconnect($hostJoiner);
        my $refJoinerAfter=get_latest_gtid_transaction_numbers($dbhJoiner);
        $totalErrors += report_replication_consistency($hostJoiner,$refDonorBefore,$refJoinerAfter,
                                       {'joinerMode'=>1});
        $dbhJoiner->disconnect();
      }
    } else {
      # Make sure cluster GTID didn't change
      if ($refDonorBefore->{'cluster'} != $refDonorAfter->{'cluster'}) {
        print "\tERROR Master position did not increment but cluster sequence did.\n";
        $totalErrors++;
      }
      elsif ($masterPosition == $lastMasterPosition) {
        print "\tOK Master Position unchanged, cluster sequence unchanged.\n";
      } else {
        print "\tOK Master Position reset, cluster sequence unchanged.\n";  # FLUSH LOGS
      }
    }
  }
}
$dbhDonor->disconnect();

if ($totalErrors) {
  print "ERRORS REPORTED: $totalErrors\n";
}

1;

