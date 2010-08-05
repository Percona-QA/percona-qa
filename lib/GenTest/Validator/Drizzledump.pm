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

package GenTest::Validator::Drizzledump;

require Exporter;
@ISA = qw(GenTest GenTest::Validator);

use strict;

use Data::Dumper;
use GenTest;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;

sub validate {
	my ($validator, $executors, $results) = @_;

        my $query_value = $results->[0]->[0] ;

        if ($query_value == "SELECT 1")
        {
        say ("Woohoo!!  $query_value"); 
        # do some setup and whatnot
	my @files;
	my $port = '9306';

	my $database = 'drizzledump_db' ;
        my $restored_database = $database."_restore" ;
        my @basedir = $executors->[0]->dbh()->selectrow_array('SELECT @@basedir') ;
        # little kludge to get the proper basedir if drizzle was started via test-run.pl
        # such a situation sets basedir to the drizzle/tests directory and can
        # muck up efforts to get to the client directory
        my @basedir_split = split(/\//, @basedir->[0]) ;
        if (@basedir_split[-1] == 'tests')
        {
          pop(@basedir_split); 
          @basedir = join('/',@basedir_split);
        }
       
        my $drizzledump = @basedir->[0].'/client/drizzledump' ;
        my $drizzle_client = @basedir->[0].'/client/drizzle' ;

        
        # dump our database under test
	my $drizzledump_file = tmpdir()."/dump_".$$."_".$port.".sql";
        say("drizzledump file is:  $drizzledump_file");
	my $drizzledump_result = system("$drizzledump --compact --order-by-primary --host=127.0.0.1 --port=$port --user=root $database  > $drizzledump_file") ;
	return STATUS_UNKNOWN_ERROR if $drizzledump_result > 0 ;

        # restore test database from dumpfile
        say("Restoring from dumpfile...");
        my $drizzle_restore_result = system("$drizzle_client --host=127.0.0.1 --port=$port --user=root $restored_database <  $drizzledump_file") ;
        return STATUS_UNKNOWN_ERROR if $drizzle_restore_result > 0 ;

        # compare original + restored databases
        # 1) We get the list of columns for the original table (use original as it is the standard)
        # 2) Use said column list in the comparison query (will report on any rows / values not in both tables)  
        # 3) Check the rows returned
        # TODO:  Loop through all tables in the database.  Current testing / experiment stage only wanting one table at a time

        my $get_table_names = " SELECT DISTINCT(table_name) ".
                               " FROM data_dictionary.tables ". 
                               " WHERE table_schema = '".$database."'" ;

        my $table_name = $executors->[0]->dbh()->selectall_arrayref($get_table_names) ;
  
        my $get_table_columns = " SELECT column_name FROM data_dictionary.tables INNER JOIN ".
                                  " DATA_DICTIONARY.columns USING (table_schema, table_name) ".
                                  " WHERE table_schema = '".$database."'". 
                                  " AND table_name = '".$table_name."'"   ;

        my $table_columns = $executors->[0]->dbh()->selectall_arrayref($get_table_columns) ; 

        my $compare_orig_and_restored =     "SELECT MIN(TableName) as TableName, a, b ".
                                 " FROM ".
                                 " ( ".
                                 "   SELECT 'Table A' as TableName, a, b ".
                                 " FROM t1 ".
                                 " UNION ALL ".
                                 " SELECT 'Table B' as TableName, a, b ".
                                 " FROM t2 ".
                                 " ) tmp ".
                                 " GROUP BY a, b ".
                                 " HAVING COUNT(*) = 1 ORDER BY `pk` " ;

        my $diff_result = $executors->[0]->dbh()->selectall_arrayref($compare_orig_and_restored) ;

	if ($diff_result ) {
		say("Differences between the two databases were found after dump/restore from file ".$drizzledump_file );
                say("Comparison query: ".$compare_orig_and_restored ) ;
                say("Returned:  ".$diff_result) ;
		return STATUS_DATABASE_CORRUPTION ;
	} else {
		unlink($drizzledump_file);
		return STATUS_OK;
	}

  }

return STATUS_OK ;
}


1;
