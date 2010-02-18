# Copyright (C) 2010 Sun Microsystems, Inc. All rights reserved.
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

package GenTest::Server::MySQLd;

@ISA = qw(GenTest);

use DBI;
use GenTest;
use GenTest::Constants;
use if windows(), Win32::Process;
use Time::HiRes;

use strict;

use Carp;
use Data::Dumper;

use constant MYSQLD_BASEDIR => 0;
use constant MYSQLD_VARDIR => 1;
use constant MYSQLD_DATADIR => 2;
use constant MYSQLD_PORT => 3;
use constant MYSQLD_MYSQLD => 4;
use constant MYSQLD_LIBMYSQL => 5;
use constant MYSQLD_BOOT_SQL => 6;
use constant MYSQLD_STDOPTS => 7;
use constant MYSQLD_MESSAGES => 8;
use constant MYSQLD_SERVER_OPTIONS => 9;
use constant MYSQLD_AUXPID => 10;
use constant MYSQLD_SERVERPID => 11;
use constant MYSQLD_WINDOWS_PROCESS => 12;
use constant MYSQLD_DBH => 13;
use constant MYSQLD_START_DIRTY => 14;

use constant MYSQLD_PID_FILE => "mysql.pid";
use constant MYSQLD_SOCKET_FILE => "mysql.sock";
use constant MYSQLD_LOG_FILE => "mysql.err";
use constant MYSQLD_DEFAULT_PORT =>  19300;
use constant MYSQLD_DEFAULT_DATABASE => "test";



sub new {
    my $class = shift;

    my $self = $class->SUPER::new({'basedir' => MYSQLD_BASEDIR,
                                   'vardir' => MYSQLD_VARDIR,
                                   'port' => MYSQLD_PORT,
                                   'server_options' => MYSQLD_SERVER_OPTIONS,
                                   'start_dirty' => MYSQLD_START_DIRTY},@_);


    if (not defined $self->[MYSQLD_VARDIR]) {
        $self->[MYSQLD_VARDIR] = "mysql-test/var";
    }

    if (windows()) {
        ## Use unix-style path's since that's what Perl expects...
        $self->[MYSQLD_BASEDIR] =~ s/\\/\//g;
        $self->[MYSQLD_VARDIR] =~ s/\\/\//g;
        $self->[MYSQLD_DATADIR] =~ s/\\/\//g;
    }
    
    if (not $self->_absPath($self->vardir)) {
        $self->[MYSQLD_VARDIR] = $self->basedir."/".$self->vardir;
    }
    
    $self->[MYSQLD_DATADIR] = $self->[MYSQLD_VARDIR]."/data";
    
    $self->[MYSQLD_MYSQLD] = $self->_find($self->basedir,
                                          windows()?["sql/Debug"]:["sql","libexec"],
                                          windows()?"mysqld.exe":"mysqld");
    $self->[MYSQLD_BOOT_SQL] = [];
    foreach my $file ("mysql_system_tables.sql", 
                      "mysql_system_tables_data.sql", 
                      "mysql_test_data_timezone.sql",
                      "fill_help_tables.sql") {
        push(@{$self->[MYSQLD_BOOT_SQL]}, 
             $self->_find($self->basedir,["scripts","share/mysql"], $file));
    }
    
    $self->[MYSQLD_MESSAGES] = $self->_findDir($self->basedir, ["sql/share","share/mysql"], "errmsg-utf8.txt");
    
    $self->[MYSQLD_LIBMYSQL] = $self->_findDir($self->basedir, 
                                               windows()?["libmysql/Debug"]:["libmysql/.libs","lib/mysql"], 
                                               windows()?"libmysql.dll":"libmysqlclient.so");
    
    $self->[MYSQLD_STDOPTS] = ["--basedir=".$self->basedir,
                               "--datadir=".$self->datadir,
                               "--lc-messages-dir=".$self->[MYSQLD_MESSAGES],
                               "--default-storage-engine=myisam",
                               "--log-warnings=0"];
    
    push(@{$self->[MYSQLD_STDOPTS]},"--loose-skip-innodb") if not windows;
    if ($self->[MYSQLD_START_DIRTY]) {
        say("Using existing data at ".$self->datadir)
    } else {
        say("Creating database at ".$self->datadir);
        $self->createMysqlBase;
}

    return $self;
}

sub basedir {
    return $_[0]->[MYSQLD_BASEDIR];
}

sub datadir {
    return $_[0]->[MYSQLD_DATADIR];
}

sub vardir {
    return $_[0]->[MYSQLD_VARDIR];
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
    return MYSQLD_SOCKET_FILE;
}

sub pidfile {
    return $_[0]->vardir."/".MYSQLD_PID_FILE;
}

sub logfile {
    return $_[0]->vardir."/".MYSQLD_LOG_FILE;
}

sub libmysqldir {
    return $_[0]->[MYSQLD_LIBMYSQL];
}


sub generateCommand {
    my ($self, @opts) = @_;

    my $command = '"'.$self->[MYSQLD_MYSQLD].'"';
    foreach my $opt (@opts) {
        $command .= ' '.join(' ',map{'"'.$_.'"'} @$opt);
    }
    $command =~ s/\//\\/g if windows();
    return $command;
}

sub createMysqlBase  {
    my ($self) = @_;
    
    ## 1. Clean old db if any
    if (-d $self->vardir) {
        if (windows()) {
            my $vardir = $self->vardir;
            $vardir =~ s/\//\\/g;
            system('rmdir /s /q "'.$vardir.'"');
        } else {
            system('rm -rf "'.$self->vardir.'"');
        }
    }

    ## 2. Create database directory structure
    mkdir $self->vardir;
    mkdir $self->datadir;
    mkdir $self->datadir."/mysql";
    mkdir $self->datadir."/test";
    
    ## 3. Create boot file
    my $boot = $self->vardir."/boot.sql";
    open BOOT,">$boot";
    
    ## Set curren database
    print BOOT  "use mysql;\n";
    foreach my $b (@{$self->[MYSQLD_BOOT_SQL]}) {
        open B,$b;
        while (<B>) { print BOOT $_;}
        close B;
    }
    ## Don't want empty users
    print BOOT "DELETE FROM user WHERE `User` = '';\n";
    close BOOT;
    
    my $command = $self->generateCommand(["--no-defaults","--bootstrap"],
                                         $self->[MYSQLD_STDOPTS]);
    
    ## 4. Boot database
    if (windows()) {
        my $bootlog = $self->vardir."/boot.log";
        system("$command < \"$boot\" > \"$bootlog\"");
    } else {
        my $bootlog = $self->vardir."/boot.log";
        system("cat \"$boot\" | $command > \"$bootlog\"  2>&1 ");
    }
}

sub _reportError {
    say(Win32::FormatMessage(Win32::GetLastError()));
}

sub startServer {
    my ($self) = @_;
    
    my $command = $self->generateCommand(["--no-defaults"],
                                         $self->[MYSQLD_STDOPTS],
                                         ["--core-file",
                                          #"--skip-ndbcluster",
                                          "--skip-grant",
                                          "--loose-new",
                                          "--relay-log=slave-relay-bin",
                                          "--loose-innodb",
                                          "--max-allowed-packet=16Mb",	# Allow loading bigger blobs
                                          "--loose-innodb-status-file=1",
                                          "--master-retry-count=65535",
                                          "--port=".$self->port,
                                          "--socket=".$self->socketfile,
                                          "--pid-file=".$self->pidfile,
                                          "--general-log-file=".$self->logfile]);
    if (defined $self->[MYSQLD_SERVER_OPTIONS]) {
        $command = $command." ".$self->[MYSQLD_SERVER_OPTIONS]->genOpt();
    }
    
    my $serverlog = $self->vardir."/".MYSQLD_LOG_FILE;
    
    if (windows) {
        my $proc;
        my $exe = $self->[MYSQLD_MYSQLD];
        my $vardir = $self->[MYSQLD_VARDIR];
        $exe =~ s/\//\\/g;
        $vardir =~ s/\//\\/g;
        say("Starting: $exe as $command on $vardir");
        Win32::Process::Create($proc,
                               $exe,
                               $command,
                               0,
                               NORMAL_PRIORITY_CLASS(),
                               ".") || die _reportError();	
        $self->[MYSQLD_WINDOWS_PROCESS]=$proc;
        $self->[MYSQLD_SERVERPID]=$proc->GetProcessID();
    } else {
        say("Starting: $command");
        $self->[MYSQLD_AUXPID] = fork();
        if ($self->[MYSQLD_AUXPID]) {
            ## Wait for the pid file to have been created
            my $waits = 0;
            while (!-f $self->pidfile && $waits < 100) {
                Time::HiRes::sleep(0.2);
                $waits++;
            }
            my $pidfile = $self->pidfile;
            my $pid = `cat \"$pidfile\"`;
            $pid =~ m/([0-9]+)/;
            $self->[MYSQLD_SERVERPID] = int($1);
            
        } else {
            exec("$command > \"$serverlog\"  2>&1") || croak("Could not start mysql server");
        }
    }
    
    my $dbh = DBI->connect($self->dsn("mysql"),
                           undef,
                           undef,
                           {PrintError => 1,
                            RaiseError => 0,
                            AutoCommit => 1});
    
    $self->[MYSQLD_DBH] = $dbh;

    return $dbh ? STATUS_OK : STATUS_ENVIRONMENT_FAILURE;
}

sub kill {
    my ($self) = @_;
    
    if (windows()) {
        if (defined $self->[MYSQLD_WINDOWS_PROCESS]) {
            $self->[MYSQLD_WINDOWS_PROCESS]->Kill(0);
            say("Killed process ".$self->[MYSQLD_WINDOWS_PROCESS]->GetProcessId());
        }
    } else {
        if (defined $self->serverpid) {
            kill KILL => $self->serverpid;
            say("Killed process ".$self->serverpid);
        }
    }
}

sub stopServer {
    my ($self) = @_;
    
    if (defined $self->[MYSQLD_DBH]) {
        say("Stopping server on port ".$self->port);
        my $r = $self->[MYSQLD_DBH]->func('shutdown','127.0.0.1','root','admin');
        my $waits = 0;
        if ($r) {
            while (-f $self->pidfile && $waits < 100) {
                Time::HiRes::sleep(0.2);
                $waits++;
            }
        }
        if (!$r or $waits >= 100) {
            say("Server would not shut down properly");
            $self->kill;
        }
    } else {
        $self->kill;
    }
}

sub _find {
    my($self, $base,$subdir,$name) = @_;
    
    foreach my $s (@$subdir) {
        my $path  = $base."/".$s."/".$name;
        return $path if -f $path;
    }
    croak "Cannot find '$name' in ".join(",",map {"'".$base."/".$_."'"} @$subdir);
}

sub dsn {
    my ($self,$database) = @_;
    $database = "test" if not defined MYSQLD_DEFAULT_DATABASE;
    return "dbi:mysql:host=127.0.0.1:port=".
        $self->[MYSQLD_PORT].
        ":user=root:database=".$database;
}

sub _findDir {
    my($self, $base,$subdir,$name) = @_;
    
    foreach my $s (@$subdir) {
        my $path  = $base."/".$s."/".$name;
        return $base."/".$s if -f $path;
    }
    croak "Cannot find '$name' in ".join(",",map {"'".$base."/".$_."'"} @$subdir);
}

sub _absPath {
    my ($self, $path) = @_;
    
    if (windows()) {
        return 
            $path =~ m/^[A-Z]:[\/\\]/i;
    } else {
        return $path =~ m/^\//;
    }
}
