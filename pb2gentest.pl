use strict;
use POSIX;
use Cwd;

my ($basedir, $vardir, $tree, $test) = @ARGV;

#
# For further details about tests and recommended RQG options, see
# http://forge.mysql.com/wiki/RandomQueryGeneratorTests
#

# Autoflush output buffers (needed when using POSIX::_exit())
$| = 1;

#
# Prepare ENV variables
#

if (
	($^O eq 'MSWin32') ||
	($^O eq 'MSWin64')
) {
	# For tail and for cdb
	$ENV{PATH} = 'G:\pb2\scripts\randgen\bin;G:\pb2\scripts\bin;C:\Program Files\Debugging Tools for Windows (x86);'.$ENV{PATH};
	$ENV{_NT_SYMBOL_PATH} = 'srv*c:\\cdb_symbols*http://msdl.microsoft.com/download/symbols;cache*c:\\cdb_symbols';

	# For vlad
	#ENV{MYSQL_FULL_MINIDUMP} = 1;

	system("date /T");
	system("time /T");
} elsif ($^O eq 'solaris') {
	# For libmysqlclient
	$ENV{LD_LIBRARY_PATH}=$ENV{LD_LIBRARY_PATH}.':/export/home/pb2/scripts/lib/';

	# For DBI and DBD::mysql
	$ENV{PERL5LIB}=$ENV{PERL5LIB}.':/export/home/pb2/scripts/DBI-1.607/:/export/home/pb2/scripts/DBI-1.607/lib:/export/home/pb2/scripts/DBI-1.607/blib/arch/:/export/home/pb2/scripts/DBD-mysql-4.008/lib/:/export/home/pb2/scripts/DBD-mysql-4.008/blib/arch/';
	
	# For c++filt
	$ENV{PATH} = $ENV{PATH}.':/opt/studio12/SUNWspro/bin';

	system("uname -a");
	system("date");
}

##
## subroutines
##

#
# Skips the test, displays reason (argument to the routine) and exits with
# exit code 0.
#
sub skip_test {
	my $reason = @_[0];
	my $message = "$test";
	# Using MTR-style output for the readers' convenience.
	# (at least 41 chars before "[ skipped ]")
	while (length $message < 40)
	{
		$message = $message.' ';
	}
        $message = $message." [ skipped ] ".$reason;
	print "$message\n";
	print localtime()." [$$] $0 will exit with exit status 0.\n";
	POSIX::_exit (0);
}

chdir('randgen');

print localtime()." [$$] Information on the host system:\n";
system("hostname");

#print localtime()." [$$] Information on Random Query Generator version:\n";
#system("bzr parent");
#system("bzr version-info");

my $cwd = cwd();

my $command;
my $engine;
my $rpl_mode;

if (($engine) = $test =~ m{(maria|falcon|innodb|myisam|pbxt)}io) {
	print "Detected that this test is about the $engine engine.\n";
}

if (($rpl_mode) = $test =~ m{(rbr|sbr|mbr|statement|mixed|row)}io) {
	print "Detected that this test is about replication mode $rpl_mode.\n";
	$rpl_mode = 'mixed' if $rpl_mode eq 'mbr';
	$rpl_mode = 'statement' if $rpl_mode eq 'sbr';
	$rpl_mode = 'row' if $rpl_mode eq 'rbr';
}

#
# Start defining tests. Test name can be whatever matches the regex in the if().
# TODO: Define less ambiguous test names to avoid accidental misconfiguration.
# Starting out with "legacy" Falcon tests.
#
if ($test =~ m{transactions}io ) {
	$command = '
		--grammar=conf/transactions.yy
		--gendata=conf/transactions.zz
		--mysqld=--falcon-consistent-read=1
		--mysqld=--transaction-isolation=REPEATABLE-READ
		--validator=DatabaseConsistency
		--mem
	';
} elsif ($test =~ m{durability}io ) {
	$command = '
		--grammar=conf/transaction_durability.yy
		--vardir1='.$vardir.'/vardir-'.$engine.'
		--vardir2='.$vardir.'/vardir-innodb
		--mysqld=--default-storage-engine='.$engine.'
		--mysqld=--falcon-checkpoint-schedule=\'1 1 1 1 1\'
		--mysqld2=--default-storage-engine=Innodb
		--validator=ResultsetComparator
	';
} elsif ($test =~ m{repeatable_read}io ) {
	$command = '
		--grammar=conf/repeatable_read.yy
		--gendata=conf/transactions.zz
		--mysqld=--falcon-consistent-read=1
		--mysqld=--transaction-isolation=REPEATABLE-READ
		--validator=RepeatableRead
		--mysqld=--falcon-consistent-read=1
		--mem
	';
} elsif ($test =~ m{blob_recovery}io ) {
	$command = '
		--grammar=conf/falcon_blobs.yy
		--gendata=conf/falcon_blobs.zz
		--duration=130
		--threads=1
		--mysqld=--falcon-page-cache-size=128M
	';
} elsif ($test =~ m{many_indexes}io ) {
	$command = '
		--grammar=conf/many_indexes.yy
		--gendata=conf/many_indexes.zz
	';
} elsif ($test =~ m{chill_thaw_compare}io) {
	$command = '
	        --grammar=conf/falcon_chill_thaw.yy
		--gendata=conf/falcon_chill_thaw.zz
	        --mysqld=--falcon-record-chill-threshold=1K
	        --mysqld=--falcon-index-chill-threshold=1K 
		--threads=1
		--vardir1='.$vardir.'/chillthaw-vardir
		--vardir2='.$vardir.'/default-vardir
		--reporters=Deadlock,ErrorLog,Backtrace
	';
} elsif ($test =~ m{chill_thaw}io) {
	$command = '
	        --grammar=conf/falcon_chill_thaw.yy 
	        --mysqld=--falcon-index-chill-threshold=4K 
	        --mysqld=--falcon-record-chill-threshold=4K
	';
} elsif ($test =~ m{online_alter}io) {
	$command = '
	        --grammar=conf/falcon_online_alter.yy 
	';
} elsif ($test =~ m{ddl}io) {
	$command = '
	        --grammar=conf/falcon_ddl.yy
	';
} elsif ($test =~ m{limit_compare_self}io ) {
	$command = '
		--grammar=conf/falcon_nolimit.yy
		--threads=1
		--validator=Limit
	';
} elsif ($test =~ m{limit_compare_innodb}io ) {
	$command = '
		--grammar=conf/limit_compare.yy
		--vardir1='.$vardir.'/vardir-falcon
		--vardir2='.$vardir.'/vardir-innodb
		--mysqld=--default-storage-engine=Falcon
		--mysqld2=--default-storage-engine=Innodb
		--threads=1
		--reporters=
	';
} elsif ($test =~ m{limit}io ) {
	$command = '
	        --grammar=conf/falcon_limit.yy
		--mysqld=--loose-maria-pagecache-buffer-size=64M
	';
} elsif ($test =~ m{recovery}io ) {
	$command = '
	        --grammar=conf/falcon_recovery.yy
		--gendata=conf/falcon_recovery.zz
		--mysqld=--falcon-checkpoint-schedule="1 1 1 1 1"
	';
} elsif ($test =~ m{pagesize_32K}io ) {
	$command = '
		--grammar=conf/falcon_pagesize.yy
		--mysqld=--falcon-page-size=32K
		--gendata=conf/falcon_pagesize32K.zz
	';
} elsif ($test =~ m{pagesize_2K}io) {
	$command = '
		--grammar=conf/falcon_pagesize.yy
		--mysqld=--falcon-page-size=2K
		--gendata=conf/falcon_pagesize2K.zz
	';
} elsif ($test =~ m{select_autocommit}io) {
	$command = '
		--grammar=conf/falcon_select_autocommit.yy
		--queries=10000000
	';
} elsif ($test =~ m{tiny_inserts}io) {
	$command = '
		--gendata=conf/falcon_tiny_inserts.zz
		--grammar=conf/falcon_tiny_inserts.yy
		--queries=10000000
	';
} elsif ($test =~ m{backlog}io ) {
	$command = '
		--grammar=conf/falcon_backlog.yy
		--gendata=conf/falcon_backlog.zz
		--mysqld=--transaction-isolation=REPEATABLE-READ
		--mysqld=--falcon-record-memory-max=10M
		--mysqld=--falcon-record-chill-threshold=1K
		--mysqld=--falcon-page-cache-size=128M
	';
} elsif ($test =~ m{compare_self}io ) {
	$command = '
		--grammar=conf/falcon_data_types.yy
		--gendata=conf/falcon_data_types.zz
		--vardir1='.$vardir.'/falcon-vardir1
		--vardir2='.$vardir.'/falcon-vardir2
		--threads=1
		--reporters=
	';
} elsif ($test =~ m{falcon_compare_innodb}io ) {
        # Datatypes YEAR and TIME disabled in grammars due to Bug#45499 (InnoDB). 
        # Revert to falcon_data_types.{yy|zz} when that bug is resolved in relevant branches.
	$command = '
		--grammar=conf/falcon_data_types_no_year_time.yy
		--gendata=conf/falcon_data_types_no_year_time.zz
		--vardir1='.$vardir.'/vardir-falcon
		--vardir2='.$vardir.'/vardir-innodb
		--mysqld=--default-storage-engine=Falcon
		--mysqld2=--default-storage-engine=Innodb
		--threads=1
		--reporters=
	';
#
# END OF FALCON TESTS
#
} elsif ($test =~ m{^info_schema$}io ) {
	$command = '
		--grammar=conf/information_schema.yy
		--threads=10
		--duration=300
	';
} elsif ($test =~ m{signal_resignal}io ) {
	$command = '
		--threads=10
		--queries=1M
		--duration=300
		--grammar=conf/signal_resignal.yy
		--mysqld=--max-sp-recursion-depth=10
	';
} elsif ($test =~ m{stress}io ) {
	$command = '
		--grammar=conf/maria_stress.yy
	';
} elsif ($test =~ m{dml_alter}io ) {
	$command = '
		--gendata=conf/maria.zz
		--grammar=conf/maria_dml_alter.yy
	';
} elsif ($test =~ m{mostly_selects}io ) {
	$command = '
		--gendata=conf/maria.zz
		--grammar=conf/maria_mostly_selects.yy
	';
} elsif ($test =~ m{bulk_insert}io ) {
	$command = '
		--grammar=conf/maria_bulk_insert.yy
	';
} elsif ($test =~ m{^rpl_.*?_simple$}io) {
	$command = '
		--gendata=conf/replication_single_engine.zz
		--grammar=conf/replication_simple.yy
		--mysqld=--log-output=table,file
	';
} elsif ($test =~ m{^rpl_semisync$}io) {
	# --rpl_mode=default is used because the .YY file changes the binary log format dynamically.
	# --threads=1 is used to avoid any replication failures due to concurrent DDL.
	# --validator= line will remove the default replication Validator, which would otherwise
	#   report test failure when the slave I/O thread is stopped, which is OK in the context
	#   of this particular test.
	# --plugin-dir is relative (to the server's basedir)

	# File name extension for plugins varies. Using .ddl for Windows and .so for others (*nix).
	# TODO: If plugins are used for more tests, generalize e.g. into a variable for the file extension only.
	my $plugins;
	if (	($^O eq 'MSWin32') ||
		($^O eq 'MSWin64')
	) {
		$plugins = 'rpl_semi_sync_master=libsemisync_master.dll:rpl_semi_sync_slave=libsemisync_slave.dll';

		# We are on Windows OS, but the feature (semisynchroneous replication (plugins))
		# is not yet supported there, so we skip this test for the time being.
		skip_test("This feature/test does not support the Windows platform at this time");
	} else {
		$plugins = 'rpl_semi_sync_master=libsemisync_master.so:rpl_semi_sync_slave=libsemisync_slave.so';
	}
	$command = "
		--gendata=conf/replication_single_engine.zz
		--engine=InnoDB
		--grammar=conf/replication.yy
		--rpl_mode=default
		--mysqld=--plugin-dir=$basedir/plugin/semisync/.libs
		--mysqld=--plugin-load=$plugins
		--mysqld=--rpl_semi_sync_master_enabled=1
		--mysqld=--rpl_semi_sync_slave_enabled=1
		--reporters=ReplicationSemiSync,Deadlock,Backtrace,ErrorLog
		--validator=
		--threads=1
		--duration=300
		--queries=1M
	";
} elsif ($test =~ m{complex}io) {
	$command = '
		--gendata=conf/replication_single_engine_pk.zz
		--grammar=conf/replication.yy
		--mysqld=--log-output=table,file
	';
} elsif ($test =~ m{optimizer_semijoin$}io) {
	$command = '
		--grammar=conf/subquery_semijoin.yy
		--mysqld=--log-output=table,file
	';
} elsif ($test =~ m{optimizer_semijoin_nested}io) {
	$command = '
		--grammar=conf/subquery_semijoin_nested.yy
		--mysqld=--log-output=table,file
	';
} elsif ($test =~ m{optimizer_semijoin_compare}io) {
	$command = '
		--threads=1
		--engine=Innodb
		--grammar=conf/subquery_semijoin.yy
		--mysqld=--log-output=table,file
		--vardir1='.$vardir.'/vardir-semijoin
		--vardir2='.$vardir.'/vardir-nosemijoin
		--validator=ResultsetComparator
		--mysqld2=--init-file='.$cwd.'/init/no_semijoin.sql
		--reporters=
	';
} elsif ($test =~ m{optimizer_materialization_compare}io) {
	$command = '
		--threads=1
		--engine=Innodb
		--grammar=conf/subquery_materialization.yy
		--mysqld=--log-output=table,file
		--vardir1='.$vardir.'/vardir-materialization
		--vardir2='.$vardir.'/vardir-nomaterialization
		--validator=ResultsetComparator
		--mysqld2=--init-file='.$cwd.'/init/no_materialization.sql
		--reporters=
	';
} elsif ($test =~ m{optimizer_semijoin_engines}io) {
	$command = '
		--threads=1
		--grammar=conf/subquery_semijoin.yy
		--mysqld=--log-output=table,file
		--mysqld=--default-storage-engine=MyISAM
		--mysqld2=--default-storage-engine=Innodb
		--vardir1='.$vardir.'/vardir-myisam
		--vardir2='.$vardir.'/vardir-innodb
		--validator=ResultsetComparator
		--reporters=
	';
} elsif ($test =~ m{optimizer_semijoin_orderby}io) {
	$command = '
		--threads=1
		--grammar=conf/subquery_semijoin.yy
		--validator=OrderBy
		--mysqld=--log-output=table,file
	';
} elsif ($test =~ m{optimizer_subquery_stability}io) {
	$command = '
		--threads=1
		--grammar=conf/subquery_materialization.yy
		--validator=SelectStability
	';
} elsif ($test =~ m{^backup_.*?_simple$}io) {
	$command = '
		--grammar=conf/backup_simple.yy
		--reporters=Deadlock,ErrorLog,Backtrace
	';
} elsif ($test =~ m{^backup_.*?_consistency$}io) {
	$command = '
		--gendata=conf/invariant.zz
		--grammar=conf/invariant.yy
		--validator=Invariant
		--reporters=Deadlock,ErrorLog,Backtrace,BackupAndRestoreInvariant,Shutdown
		--duration=600
		--threads=25
	';
}

#
# Specify some "default" Reporters if none have been specified already.
# The RQG itself also specifies some default values for some options if not set.
#
if ($command =~ m{--reporters}io) {
	# Reporters have already been specified	
} elsif ($test =~ m{rpl}io ) {
	# Don't include Recovery for replication tests, because
	$command = $command.' --reporters=Deadlock,ErrorLog,Backtrace';
} elsif ($test =~ m{falcon}io ) {
	# Include the Recovery reporter for Falcon tests in order to test
	# recovery by default after each such test.
	$command = $command.' --reporters=Deadlock,ErrorLog,Backtrace,Recovery,Shutdown';
	# Falcon-only options (avoid "unknown variable" warnings in non-Falcon builds)
	$command = $command.' --mysqld=--loose-falcon-lock-wait-timeout=5 --mysqld=--loose-falcon-debug-mask=2';
} else {
	# Default reporters for tests whose name does not contain "rpl" or "falcon"
	$command = $command.' --reporters=Deadlock,ErrorLog,Backtrace,Shutdown';
}

if ($command !~ m{--duration}io ) {
	if ($rpl_mode ne '') {
		$command = $command.' --duration=600';
	} else {
		$command = $command.' --duration=1200';
	}
}

if ($command !~ m{--vardir}io && $command !~ m{--mem}io ) {
	$command = $command." --vardir=\"$vardir\"";
}

if ($command !~ m{--log-output}io) {
	$command = $command.' --mysqld=--log-output=file';
}

if ($command !~ m{--queries}io) {
	$command = $command.' --queries=100000';
}

if (($command !~ m{--(engine|default-storage-engine)}io) && (defined $engine)) {
	$command = $command." --engine=$engine";
}

if (($command !~ m{--rpl_mode}io)  && ($rpl_mode ne '')) {
	$command = $command." --rpl_mode=$rpl_mode";
}
	
$command = "perl runall.pl --basedir=\"$basedir\" --mysqld=--loose-innodb-lock-wait-timeout=5 --mysqld=--table-lock-wait-timeout=5 --mysqld=--skip-safemalloc ".$command;

$command =~ s{[\r\n\t]}{ }sgio;
my $command_result = system($command);

if (
	($^O ne 'MSWin32') &&
	($^O ne 'MSWin64')
) {
	system("killall -15 mysqld");
	system("ps -A | grep mysqld | awk -F' ' '{ print \$1 }' | xargs kill -15");
	sleep(5);
	system("killall -9 mysqld");
	system("ps -A | grep mysqld | awk -F' ' '{ print \$1 }' | xargs kill -9");
}

POSIX::_exit ($command_result >> 8);
