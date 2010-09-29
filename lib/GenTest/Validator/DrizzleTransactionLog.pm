# Copyright (C) 2010 Patrick Crews. All rights reserved.
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

# This Validator is intended to work with the single-threaded
# grammars in randgen/conf/drizzle
# It is designed to work with a single-threaded randgen run,
# generating SQL from the transaction_log and attempting
# to replicate the original server from this.
#
# It requires another drizzle server to be running
# The port is hard-coded, but you can edit it here via
# the $validator_port variable.


package GenTest::Validator::DrizzleTransactionLog;
require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use Data::Dumper;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

use constant SERVER1_FILE_NAME  => 0;
use constant SERVER2_FILE_NAME  => 1;

sub validate {
	my ($validator, $executors, $results) = @_;
        my $fail_count ;
        my $total_count ;
        my $query_value = $results->[0]->[0] ;
        if ($query_value eq ' SELECT 1')
        {
          # do some setup and whatnot

	  my $validator_port = '9307';
          # get datadir as we need it to know where to find transaction.log
          my @datadir = $executors->[0]->dbh()->selectrow_array('SELECT @@datadir') ;

          my @basedir = $executors->[0]->dbh()->selectrow_array('SELECT @@basedir') ;
          # little kludge to get the proper basedir if drizzle was started via test-run.pl
          # such a situation sets basedir to the drizzle/tests directory and can
          # muck up efforts to get to the client directory
          my @basedir_split = split(/\//, @basedir->[0]) ;
          if (@basedir_split[-1] eq 'tests')
          {
            pop(@basedir_split); 
            @basedir = join('/',@basedir_split);
          }
       
          my $drizzledump = @basedir->[0].'/client/drizzledump' ;
          my $drizzle_client = @basedir->[0].'/client/drizzle' ;
          my $transaction_reader = @basedir->[0].'/drizzled/message/transaction_reader' ;
          my $transaction_log = @datadir->[0].'/local/transaction.log' ;


          # We now attempt to replicate from the transaction log
          # We call transaction_reader and send the output
          # via the drizzle client to the validation server (slave)
          my $transaction_log_sql_file = tmpdir()."/translog_".$$."_.sql" ;
          if (rqg_debug()) 
          {
            say("transaction_log output file:  $transaction_log_sql_file");
            say("$transaction_reader $transaction_log > $transaction_log_sql_file");
          }
          system("$transaction_reader $transaction_log > $transaction_log_sql_file") ;
           if (rqg_debug()) 
          {
            say("Replicating from transaction_log output...");
          }
          my $drizzle_rpl_result = system("$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root test <  $transaction_log_sql_file") ;
          if (rqg_debug())
          {
            say ("$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root test <  $transaction_log_sql_file");
            say ("$drizzle_rpl_result");
          }
          return STATUS_UNKNOWN_ERROR if $drizzle_rpl_result > 0 ;

          
        
          my @files;
	  my @ports = ('9306', $validator_port);

	  foreach my $port_id (0..1) 
          {
	    $files[$port_id] = tmpdir()."/translog_rpl_dump_".$$."_".$ports[$port_id].".sql";
            say("$files[$port_id]");
	    my $drizzledump_result = system("$drizzledump --compact --order-by-primary --skip-extended-insert --host=127.0.0.1 --port=$ports[$port_id] --user=root test >$files[$port_id]");
            # disable pipe to 'sort' from drizzledump call above
            #| sort > $files[$port_id]");
	    return STATUS_UNKNOWN_ERROR if $drizzledump_result > 0;
	  }
          if (rqg_debug())
          {
            say ("Executing diff --unified $files[SERVER1_FILE_NAME] $files[SERVER2_FILE_NAME]");
	  }
          my $diff_result = system("diff --unified $files[SERVER1_FILE_NAME] $files[SERVER2_FILE_NAME]");
	  $diff_result = $diff_result >> 8;
          if (rqg_debug())
          {
            say ("Cleaning up validation server...");
          }
          system("$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root -e 'DROP SCHEMA test'");

          if (rqg_debug())
          {
            say ("Resetting validation server...");
          }
          system("$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root -e 'CREATE SCHEMA test'");

	  return STATUS_UNKNOWN_ERROR if $diff_result > 1;

	  if ($diff_result == 1) 
          {
	    say("Differences between the two servers were found after comparing dumpfiles");
            say("diff command:  diff --unified $files[SERVER1_FILE_NAME] $files[SERVER2_FILE_NAME]");
            say("Master dumpfile:  $files[SERVER1_FILE_NAME]");
            say("Slave dumpfile:   $files[SERVER2_FILE_NAME]");
	    return STATUS_REPLICATION_FAILURE;
	  } 
          else 
          {
	    foreach my $file (@files) 
            {
	      unlink($file);
	    }
	    return STATUS_OK;
	  }


  }



}
1;
