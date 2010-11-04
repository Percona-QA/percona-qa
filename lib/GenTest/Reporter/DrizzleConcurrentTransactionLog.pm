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

package GenTest::Reporter::DrizzleConcurrentTransactionLog1;

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

use constant SERVER1_FILE_NAME  => 0;
use constant SERVER2_FILE_NAME  => 1;

sub report 
  {
	my $reporter = shift;

	my $dbh = DBI->connect($reporter->dsn(), undef, undef, {PrintError => 0});
	my $pid = $reporter->serverInfo('pid');
        
        # do some setup and whatnot
        my $main_port = '9306';
        my $database = 'test';
        my $new_database = 'orig_test';
        my @basedir= $dbh->selectrow_array('SELECT @@basedir');
        my @datadir= $dbh->selectrow_array('SELECT @@datadir');
     
        my $drizzledump = @basedir->[0].'/client/drizzledump' ;
        my $drizzle_client = @basedir->[0].'/client/drizzle' ;
        my $transaction_reader = @basedir->[0].'/drizzled/message/transaction_reader' ;
        my $transaction_log = @basedir->[0].'/tests/var/master-data/local/transaction.log' ;
        # Dump the original test db - we will use this for comparison
        # purposes once we have attempted to restore from the 
        # transaction log
        if (rqg_debug())
        {
            say("Dumping original test db...")
        }
        my $original_dumpfile = tmpdir()."/translog_rpl_dump_".$$."_orig.sql";
        say("$original_dumpfile");
        say("$drizzledump --compact --skip-extended-insert --host=127.0.0.1 --port=$main_port --user=root $database >$original_dumpfile");
	my $drizzledump_result = system("$drizzledump --compact --skip-extended-insert --host=127.0.0.1 --port=$main_port --user=root $database >$original_dumpfile");
        if ($drizzledump_result > 0)
        {
            say("$drizzledump_result");
	    return STATUS_UNKNOWN_ERROR;
        }
        
        # We now call transaction_reader to produce SQL from the log file contents
        my $transaction_log_sql_file = tmpdir()."/translog_".$$."_.sql" ;
        if (rqg_debug()) 
        {
          say("transaction_log output file:  $transaction_log_sql_file");
          say("$transaction_reader $transaction_log > $transaction_log_sql_file");
        }
        system("$transaction_reader $transaction_log > $transaction_log_sql_file") ;

        # We 'rename' the original test db so that we can restore from 
        # the transaction log.  By rename, we do:
        # RENAME TABLE org_db.table_name TO new_db.table_name;
        if (rqg_debug())
        {
           say ("Cleaning up validation server...");
        }
        system("$drizzle_client --host=127.0.0.1 --port=$main_port --user=root -e 'DROP SCHEMA IF EXISTS $new_database'");

        if (rqg_debug())
        {
          say ("Resetting validation server...");
        }
        my $create_schema_result = system("$drizzle_client --host=127.0.0.1 --port=$main_port --user=root -e 'CREATE SCHEMA $new_database'");
        say("$create_schema_result");      
        my $get_table_names =  " SELECT DISTINCT(table_name) ".
                                 " FROM data_dictionary.tables ". 
                                 " WHERE table_schema = '".$database."'" ;

        # Here, we get the name of the single table in the test db
        # Need to change the perl to better deal with a list of tables (more than 1)
        my $table_names = $dbh->selectcol_arrayref($get_table_names) ;

        foreach(@$table_names)
        {
          my $rename_command = "RENAME TABLE $database.$_ TO $new_database.$_";
          say("$rename_command");
          system("$drizzle_client --host=127.0.0.1 --port=$main_port --user=root -e '$rename_command'"); 

        }
        # Now, we attempt to replicate from the SQL generated via transaction_reader
        # from the transaction log
        if (rqg_debug()) 
        {
          say("Replicating from transaction_log output...");
        }
        my $drizzle_rpl_result = system("$drizzle_client --host=127.0.0.1 --port=$main_port --user=root $database <  $transaction_log_sql_file") ;
        if (rqg_debug())
        {
          say ("$drizzle_client --host=127.0.0.1 --port=$main_port --user=root $database <  $transaction_log_sql_file");
        }
        return STATUS_UNKNOWN_ERROR if $drizzle_rpl_result > 0 ;

          
        if (rqg_debug())
        {
          say("Validating replication via dumpfile compare...");
        }
        # Dump the 'replicated' test db - we will use this for comparison
        # purposes once we have attempted to restore from the 
        # transaction log
        if (rqg_debug())
        {
            say("Dumping replicated test db...")
        }
        my $restored_dumpfile = tmpdir()."/translog_rpl_dump_".$$."_restored.sql";
        say("$restored_dumpfile");
        say("$drizzledump --compact --skip-extended-insert --host=127.0.0.1 --port=$main_port --user=root $database >$restored_dumpfile");
        my $drizzledump_result = system("$drizzledump --compact --skip-extended-insert --host=127.0.0.1 --port=$main_port --user=root $database >$restored_dumpfile");
        if ($drizzledump_result > 0)
        {
            say("$drizzledump_result");
            return STATUS_UNKNOWN_ERROR;
        }

        if (rqg_debug())
        {
          say ("Executing diff --unified $original_dumpfile $restored_dumpfile");
        }
        my $diff_result = system("diff --unified $original_dumpfile $restored_dumpfile");
        $diff_result = $diff_result >> 8;
        return STATUS_UNKNOWN_ERROR if $diff_result > 1;
        if ($diff_result == 1) 
        {
          say("Differences between the two servers were found after comparing dumpfiles");
          say("diff command:  diff --unified $original_dumpfile $restored_dumpfile");
          say("Master dumpfile:  $original_dumpfile");
          say("Slave dumpfile:   $restored_dumpfile");
          return STATUS_REPLICATION_FAILURE;
        } 
        else 
        {
	  unlink $original_dumpfile;
          unlink $restored_dumpfile;
          unlink $transaction_log_sql_file;
          return STATUS_OK;
        }

   }	
	
 

sub type {
	return REPORTER_TYPE_ALWAYS;
}

1;
