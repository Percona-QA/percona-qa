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

package GenTest::Reporter::DrizzleTransactionLog;

require Exporter;
@ISA = qw(GenTest::Reporter);

use strict;
use DBI;
use GenTest;
use GenTest::Constants;
use GenTest::Reporter;
use Data::Dumper;
use IPC::Open2;
use IPC::Open3;
use File::Copy;

use constant SERVER1_FILE_NAME  => 0;
use constant SERVER2_FILE_NAME  => 1;

sub report 
  {
	my $reporter = shift;

	my $dbh = DBI->connect($reporter->dsn(), undef, undef, {PrintError => 0});
        my $dsn = $reporter->dsn();
        say("$dsn");
	my $pid = $reporter->serverInfo('pid');
        
        # do some setup and whatnot
        my $main_port = '9306';
	my $validator_port = '9307';
        my @basedir= $dbh->selectrow_array('SELECT @@basedir');
        my $drizzledump = @basedir->[0].'/client/drizzledump' ;
        my $drizzle_client = @basedir->[0].'/client/drizzle' ;
        my $transaction_reader; 
        if (-e @basedir->[0].'/drizzled/message/transaction_reader') 
        {
            $transaction_reader = @basedir->[0].'/drizzled/message/transaction_reader';
        }
        else 
        {
            $transaction_reader = @basedir->[0].'/plugin/transaction_log/utilities/transaction_reader' ;
        }

        # NOTE:  We need to edit this depending on whether we run via d-a or
        # whatever.  We don't have a good means for finding the transaction log otherwise
        # my $transaction_log = @basedir->[0].'tests/var/master-data/local/transaction.log' ;
        my $transaction_log = @basedir->[0].'/var/local/transaction.log' ;
        my $transaction_log_copy = tmpdir()."/translog_".$$."_.log" ;
        copy($transaction_log, $transaction_log_copy);


        # We now attempt to replicate from the transaction log
        # We call transaction_reader and send the output
        # via the drizzle client to the validation server (slave)
        my $transaction_log_sql_file = tmpdir()."/translog_".$$."_.sql" ;
        say("transaction_log output file:  $transaction_log_sql_file");
        say("$transaction_reader $transaction_log > $transaction_log_sql_file");
        system("$transaction_reader $transaction_log > $transaction_log_sql_file") ;
        say("Replicating from transaction_log output...");
        # We need to alter this depending on where we run
        my $rpl_command = "$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root test <  $transaction_log_sql_file";
        # setup for test-run runs
        # my $rpl_command = "$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root test <  $transaction_log_sql_file"; 
        say ("$rpl_command");
        my $drizzle_rpl_result = system($rpl_command) ;
        return STATUS_UNKNOWN_ERROR if $drizzle_rpl_result > 0 ;

          
        say("Validating replication via dumpfile compare...");
        my @files;
        my @ports = ($main_port, $validator_port);

        foreach my $port_id (0..1) 
          {
            $files[$port_id] = tmpdir()."/translog_rpl_dump_".$$."_".$ports[$port_id].".sql";
            say("$files[$port_id]");
            say("$drizzledump --compact --skip-extended-insert --host=127.0.0.1 --port=$ports[$port_id] --user=root test >$files[$port_id]");
	    my $drizzledump_result = system("$drizzledump --compact --skip-extended-insert --host=127.0.0.1 --port=$ports[$port_id] --user=root test >$files[$port_id]");
            # disable pipe to 'sort' from drizzledump call above
            #| sort > $files[$port_id]");
	    return STATUS_UNKNOWN_ERROR if $drizzledump_result > 0;
	  }
         say ("Executing diff --unified $files[SERVER1_FILE_NAME] $files[SERVER2_FILE_NAME]");
         my $diff_result = system("diff --unified $files[SERVER1_FILE_NAME] $files[SERVER2_FILE_NAME]");
	 $diff_result = $diff_result >> 8;
         say ("Cleaning up validation server...");
         system("$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root -e 'DROP SCHEMA test'");

         say ("Resetting validation server...");
         my $create_schema_result = system("$drizzle_client --host=127.0.0.1 --port=$validator_port --user=root -e 'CREATE SCHEMA test'");
         say("$create_schema_result");      

	 return STATUS_UNKNOWN_ERROR if $diff_result > 1;

	 if ($diff_result == 1) 
         {
	   say("Differences between the two servers were found after comparing dumpfiles");
           say("diff command:  diff --unified $files[SERVER1_FILE_NAME] $files[SERVER2_FILE_NAME]");
           say("Master dumpfile:  $files[SERVER1_FILE_NAME]");
           say("Slave dumpfile:   $files[SERVER2_FILE_NAME]");
           say("Transaction log:  $transaction_log_copy");
	   return STATUS_REPLICATION_FAILURE;
	 } 
         else 
         {
	   foreach my $file (@files) 
           {
	     unlink($file);
	   }
           unlink($transaction_log_sql_file);
           unlink($transaction_log_copy);
	   return STATUS_OK;
	 }

   }	
	
 

sub type {
	return REPORTER_TYPE_ALWAYS;
}

1;
