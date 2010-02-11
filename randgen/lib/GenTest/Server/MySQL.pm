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

package GenTest::Server::MySQL;

@ISA = qw(GenTest);

use GenTest;
use if windows(), Win32::Process;

use strict;

use Carp;
use Data::Dumper;
use File::Path qw(make_path remove_tree);

use constant MYSQLD_BASEDIR => 0;
use constant MYSQLD_DATADIR => 1;
use constant MYSQLD_PORTBASE => 2;
use constant MYSQLD_MYSQLD => 3;
use constant MYSQLD_LIBMYSQL => 4;
use constant MYSQLD_BOOT_SQL => 5;
use constant MYSQLD_STDOPTS => 6;
use constant MYSQLD_MESSAGES => 7;
use constant MYSQLD_SERVER_OPTIONS => 8;
use constant MYSQLD_PID1 => 9;
use constant MYSQLD_PID2 => 10;

use constant MYSQLD_PID_FILE => "mysql.pid";
use constant MYSQLD_SOCKET_FILE => "mysql.sock";
use constant MYSQLD_LOG_FILE => "mysql.log";

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({'basedir' => MYSQLD_BASEDIR,
                                   'datadir' => MYSQLD_DATADIR,
                                   'portbase' => MYSQLD_PORTBASE,
                                   'server_options' => MYSQLD_SERVER_OPTIONS},@_);

    if (windows()) {
	## Use unix-style path's since that's what Perl expects...
	$self->[MYSQLD_BASEDIR] =~ s/\\/\//g;
	$self->[MYSQLD_DATADIR] =~ s/\\/\//g;
    }
    
    $self->[MYSQLD_MYSQLD] = $self->_find($self->basedir,
					  windows()?["sql/Debug"]:["sql","libexec"],
					  windows()?"mysqld.exe":"mysqld");
    $self->[MYSQLD_BOOT_SQL] = [
        $self->_find($self->basedir,["scripts","share/mysql"],"mysql_system_tables.sql"),
        $self->_find($self->basedir,["scripts","share/mysql"],"mysql_system_tables_data.sql"),
        $self->_find($self->basedir,["scripts","share/mysql"],"mysql_test_data_timezone.sql"),
        $self->_find($self->basedir,["scripts","share/mysql"],"fill_help_tables.sql")];

    $self->[MYSQLD_MESSAGES] = $self->_findDir($self->basedir, ["sql/share","share/mysql"], "errmsg-utf8.txt");
    
    $self->[MYSQLD_LIBMYSQL] = $self->_findDir($self->basedir, 
					       windows()?["libmysql/Debug"]:["libmysql/.libs","lib/mysql"], 
					       windows()?"libmysql.dll":"libmysqlclient.so");
    
    $self->[MYSQLD_STDOPTS] = [join(" ",
                                    "--basedir=".$self->basedir,
                                    "--datadir=".$self->datadir,
                                    "--lc-messages-dir=".$self->[MYSQLD_MESSAGES],
                                    "--loose-skip-innodb",
                                    "--loose-skip-ndbcluster",
                                    "--default-storage-engine=myisam",
                                    "--log-warnings=0")];
    
    $self->createMysqlBase;
    
    return $self;
}

sub basedir {
    return $_[0]->[MYSQLD_BASEDIR];
}

sub datadir {
    return $_[0]->[MYSQLD_DATADIR];
}

sub portbase {
    my ($self) = @_;
    
    if (defined $self->[MYSQLD_PORTBASE]) {
        return $self->[MYSQLD_PORTBASE];
    } else {
        return 3306;
    }
}

sub serverpid {
    return $_[0]->[MYSQLD_PID2];
}

sub forkpid {
    return $_[0]->[MYSQLD_PID1];
}

sub socketfile {
    return $_[0]->datadir."/".MYSQLD_SOCKET_FILE;
}

sub pidfile {
    return $_[0]->datadir."/".MYSQLD_PID_FILE;
}

sub logfile {
    return $_[0]->datadir."/".MYSQLD_LOG_FILE;
}

sub createMysqlBase  {
    my ($self) = @_;

    ## 1. Clean old db if any
    remove_tree($self->datadir);

    ## 2. Create database directory structure
    mkdir $self->datadir;
    mkdir $self->datadir."/mysql";
    mkdir $self->datadir."/test";
    
    ## 3. Create boot file
    my $boot = $self->datadir."/boot.sql";
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
    
    ## 4. Boot database
    if (windows()) {
	my $command = join(' ',$self->[MYSQLD_MYSQLD],
			   "--no-defaults",
			   "--bootstrap",
			   @{$self->[MYSQLD_STDOPTS]});
	$command =~ s/\//\\/g;
	$boot =~ s/\//\\/g;
	my $bootlog = $self->datadir."/boot.log";
	
	system("$command < $boot");
    } else {
	my $command = join(' ',$self->[MYSQLD_MYSQLD],
			   "--no-defaults",
			   "--bootstrap",
			   @{$self->[MYSQLD_STDOPTS]});
	
	my $bootlog = $self->datadir."/boot.log";
	
	system("cat $boot | $command > $bootlog  2>&1 ");
    }
}

sub startServer {
    my ($self) = @_;

    my $command = join(' ',$self->[MYSQLD_MYSQLD],
                       "--no-defaults",
                       @{$self->[MYSQLD_STDOPTS]},
                       "--skip-grant",
                       "--port=".$self->portbase,
                       "--socket=".MYSQLD_SOCKET_FILE,
                       "--pid-file=".MYSQLD_PID_FILE);

    my $serverlog = $self->datadir."/".MYSQLD_LOG_FILE;
    
    say("Starting: $command");
    $self->[MYSQLD_PID1] = fork();
    if ($self->[MYSQLD_PID1]) {
        sleep(1); ## Wait to be sure that the PID file is there
        my $pidfile = $self->pidfile;
        my $pid = `cat $pidfile`;
        $pid =~ m/([0-9]+)/;
        $self->[MYSQLD_PID2] = int($1);
        
    } else {
        exec("$command > $serverlog  2>&1") || croak("Could not start mysql server");
    }
}

sub stopServer {
    my ($self) = @_;

    kill TERM => $self->serverpid;
}

sub _find {
    my($self, $base,$subdir,$name) = @_;
    
    foreach my $s (@$subdir) {
        my $path  = $base."/".$s."/".$name;
        return $path if -f $path;
    }
    croak "Cannot find '$name' in ".join(",",map {"'".$base."/".$_."'"} @$subdir);
}

sub _findDir {
    my($self, $base,$subdir,$name) = @_;
    
    foreach my $s (@$subdir) {
        my $path  = $base."/".$s."/".$name;
        return $base."/".$s if -f $path;
    }
    croak "Cannot find '$name' in ".join(",",map {"'".$base."/".$_."'"} @$subdir);
}

