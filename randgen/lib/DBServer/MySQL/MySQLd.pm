# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved. 
# Copyright (c) 2013, Monty Program Ab.
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

package DBServer::MySQL::MySQLd;

@ISA = qw(DBServer::DBServer);

use DBI;
use DBServer::DBServer;
use if osWindows(), Win32::Process;
use Time::HiRes;
use POSIX ":sys_wait_h";

use strict;

use Carp;
use Data::Dumper;
use File::Path qw(mkpath rmtree);
use File::Spec::Functions qw(catfile);

# Cache for _isMariaDB; keyed by binary path. MySQLd objects are ARRAY refs,
# so do not stash this as $self->{...}.
my %_rqg_mariadb_by_binary;

use constant MYSQLD_BASEDIR => 0;
use constant MYSQLD_VARDIR => 1;
use constant MYSQLD_DATADIR => 2;
use constant MYSQLD_PORT => 3;
use constant MYSQLD_MYSQLD => 4;
use constant MYSQLD_LIBMYSQL => 5;
use constant MYSQLD_BOOT_SQL => 6;
use constant MYSQLD_STDOPTS => 7;
use constant MYSQLD_MESSAGES => 8;
use constant MYSQLD_CHARSETS => 9;
use constant MYSQLD_SERVER_OPTIONS => 10;
use constant MYSQLD_AUXPID => 11;
use constant MYSQLD_SERVERPID => 12;
use constant MYSQLD_WINDOWS_PROCESS => 13;
use constant MYSQLD_DBH => 14;
use constant MYSQLD_START_DIRTY => 15;
use constant MYSQLD_VALGRIND => 16;
use constant MYSQLD_VALGRIND_OPTIONS => 17;
use constant MYSQLD_VERSION => 18;
use constant MYSQLD_DUMPER => 19;
use constant MYSQLD_SOURCEDIR => 20;
use constant MYSQLD_GENERAL_LOG => 21;
use constant MYSQLD_WINDOWS_PROCESS_EXITCODE => 22;
use constant MYSQLD_DEBUG_SERVER => 22;
use constant MYSQLD_SERVER_TYPE => 23;
use constant MYSQLD_VALGRIND_SUPPRESSION_FILE => 24;
use constant MYSQLD_TMPDIR => 25;

use constant MYSQLD_PID_FILE => "mysql.pid";
use constant MYSQLD_ERRORLOG_FILE => "mysql.err";
use constant MYSQLD_LOG_FILE => "mysql.log";
use constant MYSQLD_DEFAULT_PORT =>  19300;
use constant MYSQLD_DEFAULT_DATABASE => "test";
use constant MYSQLD_WINDOWS_PROCESS_STILLALIVE => 259;


sub new {
    my $class = shift;
    
    my $self = $class->SUPER::new({'basedir' => MYSQLD_BASEDIR,
                                   'sourcedir' => MYSQLD_SOURCEDIR,
                                   'vardir' => MYSQLD_VARDIR,
                                   'debug_server' => MYSQLD_DEBUG_SERVER,
                                   'port' => MYSQLD_PORT,
                                   'server_options' => MYSQLD_SERVER_OPTIONS,
                                   'start_dirty' => MYSQLD_START_DIRTY,
                                   'general_log' => MYSQLD_GENERAL_LOG,
                                   'valgrind' => MYSQLD_VALGRIND,
                                   'valgrind_options' => MYSQLD_VALGRIND_OPTIONS},@_);
    
    croak "No valgrind support on windows" if osWindows() and $self->[MYSQLD_VALGRIND];
    
    if (not defined $self->[MYSQLD_VARDIR]) {
        $self->[MYSQLD_VARDIR] = "mysql-test/var";
    }
    
    if (osWindows()) {
        ## Use unix-style path's since that's what Perl expects...
        $self->[MYSQLD_BASEDIR] =~ s/\\/\//g;
        $self->[MYSQLD_VARDIR] =~ s/\\/\//g;
        $self->[MYSQLD_DATADIR] =~ s/\\/\//g;
    }
    
    if (not $self->_absPath($self->vardir)) {
        $self->[MYSQLD_VARDIR] = $self->basedir."/".$self->vardir;
    }
    
    # Default tmpdir for server.
    $self->[MYSQLD_TMPDIR] = $self->vardir."/tmp";

    $self->[MYSQLD_DATADIR] = $self->[MYSQLD_VARDIR]."/data";
    
    # Use mysqld-debug server if --debug-server option used.
    if ($self->[MYSQLD_DEBUG_SERVER]) {
        # Catch excpetion, dont exit contine search for other mysqld if debug.
        eval{
            $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                                  osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                                  osWindows()?"mysqld-debug.exe":"mysqld-debug");
        };
        # If mysqld-debug server is not found, use mysqld server if built as debug.        
        if (!$self->[MYSQLD_MYSQLD]) {
            $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                                  osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                                  osWindows()?"mysqld.exe":"mysqld");     
            if ($self->[MYSQLD_MYSQLD] && $self->serverType($self->[MYSQLD_MYSQLD]) !~ /Debug/) {
                croak "--debug-server needs a mysqld debug server, the server found is $self->[MYSQLD_SERVER_TYPE]"; 
            }
        }
    }else {
        # If mysqld server is found use it.
        eval {
            $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                                  osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                                  osWindows()?"mysqld.exe":"mysqld");
        };
        # If mysqld server is not found, use mysqld-debug server.
        if (!$self->[MYSQLD_MYSQLD]) {
            eval {
                $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                                      osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                                      osWindows()?"mysqld-debug.exe":"mysqld-debug");
            };
        }
        # MariaDB packages / builds may ship mariadbd instead of (or as well as) mysqld.
        if (!$self->[MYSQLD_MYSQLD]) {
            $self->[MYSQLD_MYSQLD] = $self->_find([$self->basedir],
                                                  osWindows()?["sql/Debug","sql/RelWithDebInfo","sql/Release","bin"]:["sql","libexec","bin","sbin"],
                                                  osWindows()?"mariadbd.exe":"mariadbd");
        }
        
        $self->serverType($self->[MYSQLD_MYSQLD]);
    }

    $self->[MYSQLD_BOOT_SQL] = [];

    $self->[MYSQLD_DUMPER] = $self->_find([$self->basedir],
                                          osWindows()?["client/Debug","client/RelWithDebInfo","client/Release","bin"]:["client","bin"],
                                          osWindows()?("mysqldump.exe","mariadb-dump.exe"):("mysqldump","mariadb-dump"));


    ## Check for CMakestuff to get hold of source dir:

    if (not defined $self->sourcedir) {
        if (-e $self->basedir."/CMakeCache.txt") {
            open CACHE, $self->basedir."/CMakeCache.txt";
            while (<CACHE>){
                if (m/^MySQL_SOURCE_DIR:STATIC=(.*)$/) {
                    $self->[MYSQLD_SOURCEDIR] = $1;
                    say("Found source directory at ".$self->[MYSQLD_SOURCEDIR]);
                    last;
                }
            }
        }
    }
   
    ## Use valgrind suppression file available in mysql-test path, but only when valgrind is requested.
    if ($self->[MYSQLD_VALGRIND]) {
        $self->[MYSQLD_VALGRIND_SUPPRESSION_FILE] = $self->_find(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                                                                 osWindows()?["share/mysql-test","mysql-test"]:["share/mysql-test","mysql-test"],
                                                                 "valgrind.supp");
    } else {
        $self->[MYSQLD_VALGRIND_SUPPRESSION_FILE] = undef;
    }
    
    foreach my $file (
        # Classic MySQL / older MariaDB names
        ["mysql_system_tables.sql", "mariadb_system_tables.sql"],
        ["mysql_performance_tables.sql", "mariadb_performance_tables.sql"],
        ["mysql_system_tables_data.sql", "mariadb_system_tables_data.sql"],
        ["mysql_test_data_timezone.sql", "mariadb_test_data_timezone.sql"],
        ["fill_help_tables.sql"],
    ) {
        my $script =
             eval { $self->_find(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir],
                          ["scripts","share/mysql","share/mariadb","share"], @$file) };
        push(@{$self->[MYSQLD_BOOT_SQL]},$script) if $script;
    }
    
    $self->[MYSQLD_MESSAGES] = 
       $self->_findDir(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir], 
                       ["sql/share","share/mysql","share/mariadb","share"], "english/errmsg.sys");

    $self->[MYSQLD_CHARSETS] =
        $self->_findDir(defined $self->sourcedir?[$self->basedir,$self->sourcedir]:[$self->basedir], 
                        ["sql/share/charsets","share/mysql/charsets","share/mariadb/charsets","share/charsets"], "Index.xml");
                         
    
    #$self->[MYSQLD_LIBMYSQL] = 
    #   $self->_findDir([$self->basedir], 
    #                   osWindows()?["libmysql/Debug","libmysql/RelWithDebInfo","libmysql/Release","lib","lib/debug","lib/opt","bin"]:["libmysql","libmysql/.libs","lib/mysql","lib"], 
    #                   osWindows()?"libmysql.dll":osMac()?"libmysqlclient.dylib":"libmysqlclient.so");
    
    my @stdopts = ("--basedir=".$self->basedir,
                   "--datadir=".$self->datadir,
                   $self->_messages,
                   "--character-sets-dir=".$self->[MYSQLD_CHARSETS],
                   "--default-storage-engine=innodb",
                   "--tmpdir=".$self->tmpdir);
    # MySQL/Percona-only; MariaDB rejects unknown system variables without --loose-
    push @stdopts, "--log_error_verbosity=1" unless $self->_isMariaDB;
    $self->[MYSQLD_STDOPTS] = \@stdopts;

    if ($self->[MYSQLD_START_DIRTY]) {
        say("Using existing data for MySQL " .$self->version ." at ".$self->datadir);
    } else {
        say("Creating MySQL " . $self->version . " database at ".$self->datadir);
        $self->createMysqlBase;
    }

    return $self;
}

sub basedir {
    return $_[0]->[MYSQLD_BASEDIR];
}

sub sourcedir {
    return $_[0]->[MYSQLD_SOURCEDIR];
}

sub datadir {
    return $_[0]->[MYSQLD_DATADIR];
}

sub vardir {
    return $_[0]->[MYSQLD_VARDIR];
}

sub tmpdir {
    return $_[0]->[MYSQLD_TMPDIR];
}

sub port {
    my ($self) = @_;
    
    if (defined $self->[MYSQLD_PORT]) {
        return $self->[MYSQLD_PORT];
    } else {
        return MYSQLD_DEFAULT_PORT;
    }
}

sub serverpid {
    return $_[0]->[MYSQLD_SERVERPID];
}

sub forkpid {
    return $_[0]->[MYSQLD_AUXPID];
}

sub socketfile {
    my ($self) = @_;
    my $socketFileName = $_[0]->vardir."/mysql.sock";
    if (length($socketFileName) >= 100) {
	$socketFileName = "/tmp/RQGmysql.".$self->port.".sock";
    }
    return $socketFileName;
}

sub pidfile {
    return $_[0]->vardir."/".MYSQLD_PID_FILE;
}

sub logfile {
    return $_[0]->vardir."/".MYSQLD_LOG_FILE;
}

sub errorlog {
    return $_[0]->vardir."/".MYSQLD_ERRORLOG_FILE;
}

sub setStartDirty {
    $_[0]->[MYSQLD_START_DIRTY] = $_[1];
}

sub valgrind_suppressionfile {
    return $_[0]->[MYSQLD_VALGRIND_SUPPRESSION_FILE] ;
}

#sub libmysqldir {
#    return $_[0]->[MYSQLD_LIBMYSQL];
#}

# Check the type of mysqld server.
sub serverType {
    my ($self, $mysqld) = @_;
    $self->[MYSQLD_SERVER_TYPE] = "Release";
    
    my $command="$mysqld --version";
    my $result=`$command 2>&1`;
    
    $self->[MYSQLD_SERVER_TYPE] = "Debug" if ($result =~ /debug/sig);
    return $self->[MYSQLD_SERVER_TYPE];
}

sub generateCommand {
    my ($self, @opts) = @_;

    my $command = '"'.$self->binary.'"';
    foreach my $opt (@opts) {
        $command .= ' '.join(' ',map{'"'.$_.'"'} @$opt);
    }
    $command =~ s/\//\\/g if osWindows();
    return $command;
}

sub addServerOptions {
    my ($self,$opts) = @_;

    push(@{$self->[MYSQLD_SERVER_OPTIONS]}, @$opts);
}

sub createMysqlBase  {
    my ($self) = @_;
    ## 1. Clean old db if any
    if (-d $self->vardir) {
        rmtree($self->vardir);
    }

    ## 2. Create database directory structure
    mkpath($self->vardir);
    mkpath($self->tmpdir);
    mkpath($self->datadir);

    # Shared boot/init SQL: ensure `test` exists after either bootstrap or --initialize.
    my $boot = catfile($self->vardir, "boot.sql");
    open(my $boot_fh, ">", $boot) or croak("Could not open $boot: $!");
    print $boot_fh "CREATE DATABASE IF NOT EXISTS test;\n";

    my $command;
    my $initlog = catfile($self->vardir, "boot.log");

    # MariaDB (and MySQL < 5.7.5) need install-db / --bootstrap.
    # MySQL/Percona 5.7.5+ use --initialize-insecure.
    # Detection must NOT use MariaDB-fork _isMySQL alone: Percona 9.x would
    # incorrectly take the bootstrap path.
    if ($self->_isMariaDB || $self->_olderThan(5, 7, 5)) {
        close $boot_fh;  # install-db creates system tables itself; keep boot.sql for optional later use

        # Prefer mariadb-install-db / mysql_install_db when available (package + build trees).
        # Raw --bootstrap against modern packaged MariaDB can hang (signal-handler teardown).
        my $install_db = eval {
            $self->_find([$self->basedir],
                         ["scripts", "bin", "sbin"],
                         "mariadb-install-db", "mysql_install_db");
        };
        if (!$install_db) {
            # Also allow a system helper when basedir is a shim pointing at /usr.
            foreach my $cand ("/usr/bin/mariadb-install-db", "/usr/sbin/mariadb-install-db",
                              "/usr/bin/mysql_install_db", "/usr/sbin/mysql_install_db") {
                if (-x $cand) { $install_db = $cand; last; }
            }
        }

        if ($install_db) {
            my $install_basedir = $self->_installDbBasedir;
            say("Initializing MariaDB/MySQL with $install_db (basedir=$install_basedir)");
            my @cmd = ($install_db,
                       "--no-defaults",
                       "--basedir=".$install_basedir,
                       "--datadir=".$self->datadir,
                       "--auth-root-authentication-method=normal",
                       "--force");  # allow install when hostname lookup fails in CI/sandbox
            my $user = getpwuid($<);
            push @cmd, "--user=$user" if defined $user && $< != 0;
            $command = join(' ', map { '"'.$_.'"' } @cmd);
        } else {
            say("Initializing with --bootstrap (" .
                ($self->_isMariaDB ? "MariaDB" : "MySQL < 5.7.5") . ")");

            if (!@{$self->[MYSQLD_BOOT_SQL]}) {
                croak("Bootstrap init requires mysql_/mariadb_system_tables*.sql under ".
                      "share/mysql or share/mariadb (basedir=".$self->basedir.")");
            }

            open($boot_fh, ">", $boot) or croak("Could not open $boot: $!");
            print $boot_fh "CREATE DATABASE IF NOT EXISTS test;\n";
            print $boot_fh "CREATE DATABASE mysql;\n";
            print $boot_fh "USE mysql;\n";
            foreach my $b (@{$self->[MYSQLD_BOOT_SQL]}) {
                open(my $bfh, "<", $b) or croak("Could not open boot SQL '$b': $!");
                while (<$bfh>) {
                    print $boot_fh $_;
                }
                close $bfh;
            }

            # MariaDB 10.4+ replaced mysql.user with mysql.global_priv.
            my $usertable = ($self->versionNumeric() gt '100400' ? 'global_priv' : 'user');
            print $boot_fh "USE mysql;\n";
            print $boot_fh "DELETE FROM $usertable WHERE `User` = '';\n";
            close $boot_fh;

            my $boot_options = [
                "--no-defaults",
                @{$self->[MYSQLD_STDOPTS]},
                "--skip-log-bin",
                "--bootstrap",
            ];
            push @$boot_options, "--loose-innodb-encrypt-tables=OFF",
                                 "--loose-innodb-encrypt-log=OFF";
            if (defined $self->[MYSQLD_SERVER_OPTIONS]) {
                push @$boot_options, @{$self->[MYSQLD_SERVER_OPTIONS]};
            }

            $command = $self->generateCommand($boot_options);
            $command = "$command < \"$boot\"";
        }
    } else {
        close $boot_fh;
        say("Initializing with --initialize-insecure (MySQL/Percona)");

        my $init_options = [
            "--no-defaults",
            "--initialize-insecure",
            "--datadir=" . $self->datadir,
            "--basedir=" . $self->basedir,
            "--init-file=$boot",
        ];
        $command = $self->generateCommand($init_options, $self->[MYSQLD_STDOPTS]);
        $initlog = catfile($self->vardir, "init.log");
    }

    say("Bootstrap/init command: $command");
    my $exit_code = system(qq{$command > "$initlog" 2>&1});
    if ($exit_code != 0) {
        croak("MySQL/MariaDB initialization failed. Check log: $initlog");
    }
}

sub _reportError {
    say(Win32::FormatMessage(Win32::GetLastError()));
}

sub startServer {
    my ($self) = @_;

    my ($v1,$v2,@rest) = $self->versionNumbers;
    my $v = $v1*1000+$v2;
    my $command = $self->generateCommand(["--no-defaults"],
                                         $self->[MYSQLD_STDOPTS],
                                         ["--core-file",
                                          #"--skip-ndbcluster",
                                          #"--skip-grant",
                                          "--loose-new",
                                          "--relay-log=slave-relay-bin",
                                          "--loose-innodb",
                                          "--max-allowed-packet=16Mb",	# Allow loading bigger blobs
                                          "--loose-innodb-status-file=1",
                                          "--master-retry-count=65535",
                                          "--port=".$self->port,
                                          "--socket=".$self->socketfile,
                                          "--pid-file=".$self->pidfile],
                                         $self->_logOptions);
    if (defined $self->[MYSQLD_SERVER_OPTIONS]) {
        $command = $command." ".join(' ',@{$self->[MYSQLD_SERVER_OPTIONS]});
    }
    # If we don't remove the existing pidfile, 
    # the server will be considered started too early, and further flow can fail
    unlink($self->pidfile);
    
    my $errorlog = $self->vardir."/".MYSQLD_ERRORLOG_FILE;
    
    if (osWindows) {
        my $proc;
        my $exe = $self->binary;
        my $vardir = $self->[MYSQLD_VARDIR];
        $exe =~ s/\//\\/g;
        $vardir =~ s/\//\\/g;
        $self->printInfo();
        say("Starting MySQL ".$self->version.": $exe as $command on $vardir");
        Win32::Process::Create($proc,
                               $exe,
                               $command,
                               0,
                               NORMAL_PRIORITY_CLASS(),
                               ".") || croak _reportError();
        $self->[MYSQLD_WINDOWS_PROCESS]=$proc;
        $self->[MYSQLD_SERVERPID]=$proc->GetProcessID();
        # Gather the exit code and check if server is running.
        $proc->GetExitCode($self->[MYSQLD_WINDOWS_PROCESS_EXITCODE]);
        if ($self->[MYSQLD_WINDOWS_PROCESS_EXITCODE] == MYSQLD_WINDOWS_PROCESS_STILLALIVE) {
            ## Wait for the pid file to have been created
            my $wait_time = 0.2;
            my $waits = 0;
            while (!-f $self->pidfile && $waits < 600) {
                Time::HiRes::sleep($wait_time);
                $waits++;
            }
            if (!-f $self->pidfile) {
                sayFile($self->errorlog);
                croak("Could not start mysql server, waited ".($waits*$wait_time)." seconds for pid file");
            }
        }
    } else {
        if ($self->[MYSQLD_VALGRIND]) {
            my $val_opt ="";
            if (defined $self->[MYSQLD_VALGRIND_OPTIONS]) {
                $val_opt = join(' ',@{$self->[MYSQLD_VALGRIND_OPTIONS]});
            }
            my $valgrind_cmd = "valgrind --time-stamp=yes --leak-check=yes";
            if (defined $self->valgrind_suppressionfile && $self->valgrind_suppressionfile ne '') {
                $valgrind_cmd .= " --suppressions=".$self->valgrind_suppressionfile;
            }
            $command = "$valgrind_cmd $val_opt ".$command;
        }
        $self->printInfo;
        say("Starting MySQL ".$self->version.": $command");
        $self->[MYSQLD_AUXPID] = fork();
        croak("Could not fork: $!") unless defined $self->[MYSQLD_AUXPID];
        if ($self->[MYSQLD_AUXPID]) {
            ## Wait for the pid file to have been created
            my $wait_time = 0.2;
            my $waits = 0;
            while (!-f $self->pidfile && $waits < 600) {
                Time::HiRes::sleep($wait_time);
                $waits++;
            }
            if (!-f $self->pidfile) {
                sayFile($self->errorlog);
                croak("Could not start mysql server, waited ".($waits*$wait_time)." seconds for pid file");
            }
            my $pidfile = $self->pidfile;
            open(my $fh, '<', $pidfile) or croak("Cannot open pidfile '$pidfile': $!");
            my $pid = <$fh>;
            close($fh);

            chomp($pid) if defined $pid;
            if (!defined $pid || $pid !~ /^(\d+)$/) {
                croak("Invalid or empty PID in pidfile '$pidfile'");
            }
            $self->[MYSQLD_SERVERPID] = int($1);
        } else {
            exec("$command > \"$errorlog\"  2>&1") || croak("Could not start mysql server");
        }
    }
    
    return $self->dbh ? DBSTATUS_OK : DBSTATUS_FAILURE;
}

sub kill {
    my ($self) = @_;
    
    if (osWindows()) {
        if (defined $self->[MYSQLD_WINDOWS_PROCESS]) {
            $self->[MYSQLD_WINDOWS_PROCESS]->Kill(0);
            say("Killed process ".$self->[MYSQLD_WINDOWS_PROCESS]->GetProcessID());
        }
    } else {
        if (defined $self->serverpid) {
            kill KILL => $self->serverpid;
            my $waits = 0;
            while ($self->running && $waits < 100) {
                Time::HiRes::sleep(0.2);
                $waits++;
            }
            if ($waits >= 100) {
                croak("Unable to kill process ".$self->serverpid);
            } else {
                say("Killed process ".$self->serverpid);
            }
        }
    }

    # clean up when the server is not alive.
    unlink $self->socketfile if -e $self->socketfile;
    unlink $self->pidfile if -e $self->pidfile;
}

sub term {
    my ($self) = @_;
    
    if (osWindows()) {
        ### Not for windows
        say("Don't know how to do SIGTERM on Windows");
        $self->kill;
    } else {
        if (defined $self->serverpid) {
            kill TERM => $self->serverpid;
            my $waits = 0;
            while ($self->running && $waits < 100) {
                Time::HiRes::sleep(0.2);
                $waits++;
            }
            if ($waits >= 100) {
                say("Unable to terminate process ".$self->serverpid." Trying kill");
                $self->kill;
            } else {
                say("Terminated process ".$self->serverpid);
            }
        }
    }
    if (-e $self->socketfile) {
        unlink $self->socketfile;
    }
}

sub crash {
    my ($self) = @_;
    
    if (osWindows()) {
        ## How do i do this?????
        $self->kill; ## Temporary
    } else {
        if (defined $self->serverpid) {
            kill SEGV => $self->serverpid;
            say("Crashed process ".$self->serverpid);
        }
    }

    # clean up when the server is not alive.
    unlink $self->socketfile if -e $self->socketfile;
    unlink $self->pidfile if -e $self->pidfile;
 
}

sub corefile {
    my ($self) = @_;

    ## Unix variant
    return $self->datadir."/core.".$self->serverpid;
}

sub dumper {
    return $_[0]->[MYSQLD_DUMPER];
}

sub dumpdb {
    my ($self,$database, $file) = @_;
    say("Dumping MySQL server ".$self->version." on port ".$self->port);
    my $dump_command = '"'.$self->dumper.
                             "\" --hex-blob --skip-triggers --compact ".
                             "--order-by-primary --skip-extended-insert ".
                             "--no-create-info --host=127.0.0.1 ".
                             "--port=".$self->port.
                             " -uroot $database";
    # --no-tablespaces option was introduced in version 5.1.14.
    if ($self->_newerThan(5,1,13)) {
        $dump_command = $dump_command . " --no-tablespaces";
    }
    my $dump_result = system("$dump_command | sort > $file");
    return $dump_result;
}

sub binary {
    return $_[0]->[MYSQLD_MYSQLD];
}

sub stopServer {
    my ($self) = @_;
    
    if (defined $self->[MYSQLD_DBH]) {
        say("Stopping server on port ".$self->port);
        ## Use dbh routine to ensure reconnect in case connection is
        ## stale (happens i.e. with mdl_stability/valgrind runs)
        my $dbh = $self->dbh();
        my $res;
        my $waits = 0;
        # Need to check if $dbh is defined, in case the server has crashed
        if (defined $dbh) {
            $res = $dbh->do("SHUTDOWN");
            if ($res) {
                while ($self->running && $waits < 100) {
                    Time::HiRes::sleep(0.2);
                    $waits++;
                }
            } else {
                ## If shutdown fails, we want to know why:
                say("Shutdown failed due to ".$dbh->err.":".$dbh->errstr);
            }
        }
        if (!$res or $waits >= 100) {
            # Terminate process
            say("Server would not shut down properly. Terminate it");
            $self->term;
        } else {
            # clean up when server is not alive.
            unlink $self->socketfile if -e $self->socketfile;
            unlink $self->pidfile if -e $self->pidfile;
        }
    } else {
        $self->kill;
    }
}

sub running {
    my($self) = @_;
    if (osWindows()) {
        ## Need better solution fir windows. This is actually the old
        ## non-working solution for unix....
        return -f $self->pidfile;
    } else {
        ## Check if the child process is active.
        my $child_status = waitpid($self->serverpid,WNOHANG);
        return $child_status != -1;
    }
}

sub _find {
    my($self, $bases, $subdir, @names) = @_;
    
    foreach my $base (@$bases) {
        foreach my $s (@$subdir) {
        	foreach my $n (@names) {
                my $path  = $base."/".$s."/".$n;
                return $path if -f $path;
        	}
        }
    }
    my $paths = "";
    foreach my $base (@$bases) {
        $paths .= join(",",map {"'".$base."/".$_."'"} @$subdir).",";
    }
    my $names = join(" or ", @names );
    croak "Cannot find '$names' in $paths"; 
}

sub dsn {
    my ($self,$database) = @_;
    $database = "test" if not defined MYSQLD_DEFAULT_DATABASE;
    return "dbi:mysql:host=127.0.0.1:port=".
        $self->[MYSQLD_PORT].
        ":user=root:database=".$database;
}

sub dbh {
    my ($self) = @_;
    if (defined $self->[MYSQLD_DBH]) {
        if (!$self->[MYSQLD_DBH]->ping) {
            say("Stale connection. Reconnecting");
            $self->[MYSQLD_DBH] = DBI->connect($self->dsn("mysql"),
                                               undef,
                                               undef,
                                               {PrintError => 0,
                                                RaiseError => 0,
                                                AutoCommit => 1});
            if(!defined $self->[MYSQLD_DBH]) {
                say("Reconnect failed due to ".$DBI::err.":".$DBI::errstr);
            }
        }
    } else {
        $self->[MYSQLD_DBH] = DBI->connect($self->dsn("mysql"),
                                           undef,
                                           undef,
                                           {PrintError => 1,
                                            RaiseError => 0,
                                            AutoCommit => 1});
    }
    return $self->[MYSQLD_DBH];
}

sub _findDir {
    my($self, $bases, $subdir, $name) = @_;
    
    foreach my $base (@$bases) {
        foreach my $s (@$subdir) {
            my $path  = $base."/".$s."/".$name;
            return $base."/".$s if -f $path;
        }
    }
    my $paths = "";
    foreach my $base (@$bases) {
        $paths .= join(",",map {"'".$base."/".$_."'"} @$subdir).",";
    }
    croak "Cannot find '$name' in $paths";
}

sub _absPath {
    my ($self, $path) = @_;
    
    if (osWindows()) {
        return 
            $path =~ m/^[A-Z]:[\/\\]/i;
    } else {
        return $path =~ m/^\//;
    }
}

sub version {
    my($self) = @_;

    if (not defined $self->[MYSQLD_VERSION]) {
        my $ver;

        # Prefer the server binary banner — mysql_config on a shim basedir can
        # point at a different product (e.g. system MySQL while binary is MariaDB).
        my $out = `"$self->[MYSQLD_MYSQLD]" --version 2>&1`;
        if ($out =~ /(\d+\.\d+\.\d+)/) {
            $ver = $1;
        }

        if (not defined $ver) {
            if (osWindows) {
                my $conf = eval {
                    $self->_find([$self->basedir],
                                 ['scripts', 'bin', 'sbin'],
                                 'mariadb_config.pl', 'mysql_config.pl');
                };
                if ($conf) {
                    $ver = `perl $conf --version`;
                }
            } else {
                my $conf = eval {
                    $self->_find([$self->basedir],
                                 ['scripts', 'bin', 'sbin'],
                                 'mariadb_config', 'mysql_config');
                };
                if ($conf) {
                    $ver = `sh "$conf" --version`;
                }
            }
        }

        if ((not defined $ver) || $ver eq '') {
            croak("Unable to determine server version from binary --version or mysql_config/mariadb_config");
        }
        chop($ver) if defined $ver && $ver =~ /\n$/;
        $ver =~ s/^\s+|\s+$//g;
        if ($ver =~ /(\d+\.\d+\.\d+)/) {
            $ver = $1;
        }
        $self->[MYSQLD_VERSION] = $ver;
    }
    return $self->[MYSQLD_VERSION];
}

sub printInfo {
    my($self) = @_;

    say("MySQL Version:". $self->version);
    say("Binary: ". $self->binary);
    say("Type: ". $self->serverType($self->binary));
    say("Datadir: ". $self->datadir);
    say("Tmpdir: ". $self->tmpdir);
    say("Corefile: " . $self->corefile);
}

sub versionNumbers {
    my($self) = @_;

    $self->version =~ m/([0-9]+)\.([0-9]+)\.([0-9]+)/;

    return (int($1),int($2),int($3));
}

sub versionNumeric {
    my $self = shift;
    $self->version =~ /([0-9]+)\.([0-9]+)\.([0-9]+)/;
    return sprintf("%02d%02d%02d", int($1), int($2), int($3));
}

#############  Version specific stuff

sub _messages {
    my ($self) = @_;

    if ($self->_olderThan(5,5,0)) {
        return "--language=".$self->[MYSQLD_MESSAGES]."/english";
    } else {
        return "--lc-messages-dir=".$self->[MYSQLD_MESSAGES];
    }
}

sub _logOptions {
    my ($self) = @_;

    if ($self->_olderThan(5,1,29)) {
        return ["--log=".$self->logfile]; 
    } else {
        if ($self->[MYSQLD_GENERAL_LOG]) {
            return ["--general-log", "--general-log-file=".$self->logfile]; 
        } else {
            return ["--general-log-file=".$self->logfile];
        }
    }
}

# Resolve a basedir that mariadb-install-db can actually use. Shim basedirs
# (symlinks to /usr/sbin/mariadbd) often lack install-db helpers; follow the
# server binary to the real install prefix when it lives outside basedir.
sub _installDbBasedir {
    my ($self) = @_;
    my $bd = $self->basedir;

    my $bin = $self->binary;
    my $guard = 0;
    while (-l $bin && $guard++ < 10) {
        my $target = readlink($bin);
        last unless defined $target;
        if ($target =~ m{^/}) {
            $bin = $target;
        } else {
            my ($vol, $dir, undef) = File::Spec->splitpath($bin);
            $bin = File::Spec->catpath($vol, $dir, $target);
        }
    }
    if ($bin =~ m{^(.*)/(?:sbin|bin|libexec)/[^/]+$}) {
        my $prefix = $1;
        # If the real binary lives under a different prefix (package shim case),
        # prefer that prefix for install-db.
        if ($prefix ne $bd && (-x "$prefix/bin/my_print_defaults"
                               || -d "$prefix/share/mariadb"
                               || -d "$prefix/share/mysql")) {
            return $prefix;
        }
    }

    return $bd if (-x "$bd/bin/my_print_defaults"
                   || -x "$bd/extra/my_print_defaults"
                   || -x "$bd/scripts/my_print_defaults");
    return $bd;
}

# True when the server binary identifies as MariaDB (not MySQL/Percona).
# Prefer the version banner over major-number heuristics so Percona 9.x stays
# on --initialize-insecure while MariaDB 10/11 use --bootstrap.
sub _isMariaDB {
    my ($self) = @_;
    my $bin = $self->[MYSQLD_MYSQLD];
    return $_rqg_mariadb_by_binary{$bin} if exists $_rqg_mariadb_by_binary{$bin};

    my $out = `"$bin" --version 2>&1`;
    my $is = ($out =~ /MariaDB/i) ? 1 : 0;
    # Fallback for odd builds that omit the word but use 10.x/11.x numbering
    # while the banner did not look like Oracle/Percona MySQL.
    if (!$is && $out !~ /Percona|Oracle|MySQL Community|mysql  Ver/i) {
        my ($v1) = $self->versionNumbers;
        $is = 1 if ($v1 == 10 || $v1 == 11);
    }
    $_rqg_mariadb_by_binary{$bin} = $is;
    return $is;
}

# For _olderThan we remap MariaDB 10.x onto MySQL 5.6/5.7 feature baselines
# (same approach as MariaDB/randgen).
sub _olderThan {
    my ($self,$b1,$b2,$b3) = @_;
    
    my ($v1, $v2, $v3) = $self->versionNumbers;

    if ($v1 == 10 and $b1 == 5 and $v2 >= 0 and $v2 < 3) { $v1 = 5; $v2 = 6 }
    elsif ($v1 == 10 and $b1 == 5 and $v2 >= 3) { $v1 = 5; $v2 = 7 }
    elsif ($v1 == 5 and $b1 == 10 and $b2 >= 0 and $b2 < 3) { $b1 = 5; $b2 = 6 }
    elsif ($v1 == 5 and $b1 == 10 and $b2 >= 3) { $b1 = 5; $b2 = 7 }

    my $b = $b1*1000 + $b2 * 100 + $b3;
    my $v = $v1*1000 + $v2 * 100 + $v3;

    return $v < $b;
}

sub _newerThan {
    my ($self,$b1,$b2,$b3) = @_;

    my ($v1, $v2, $v3) = $self->versionNumbers;

    my $b = $b1*1000 + $b2 * 100 + $b3;
    my $v = $v1*1000 + $v2 * 100 + $v3;

    return $v > $b;
}

1;

