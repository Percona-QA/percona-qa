# Copyright (C) 2010 Sun Microsystems, Inc. All rights reserved.  Use
# is subject to license terms.
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

package TestMySQLServer;

use base qw(Test::Unit::TestCase);
use lib 'lib';
use Cwd;
use GenTest;
use GenTest::Server::MySQLd;
use GenTest::Executor;

use Data::Dumper;

sub new {
    my $self = shift()->SUPER::new(@_);
    # your state for fixture here
    return $self;
}

sub set_up {
}

@pids;

sub tear_down {
    if (windows) {
        ## Need to ,kill leftover processes if there are some
        foreach my $p (@pids) {
            Win32::Process::KillProcess($p,-1);
        }
        system("rmdir /s /q unit\\tmp");
    } else {
        ## Need to ,kill leftover processes if there are some
        kill 9 => @pids;
        system("rm -rf unit/tmp");
    }
}

sub test_create_server {
    my $self = shift;

    my $vardir= cwd()."/unit/tmp";

    my $portbase = $ENV{TEST_PORTBASE}?int($ENV{TEST_PORTBASE}):22120;

    $self->assert(defined $ENV{RQG_MYSQL_BASE},"RQG_MYSQL_BASE not defined");

    my $server = GenTest::Server::MySQLd->new(basedir => $ENV{RQG_MYSQL_BASE},
                                              vardir => $vardir,
                                              port => 22120);
    $self->assert_not_null($server);
    
    $self->assert(-f $vardir."/data/mysql/db.MYD","No ".$vardir."/data/mysql/db.MYD");
    
    $server->startServer;
    push @pids,$server->serverpid;
    
    my $dsn = $server->dsn("mysql");
    $self->assert_not_null($dsn);
    
    my $executor = GenTest::Executor->newFromDSN($dsn);
    $self->assert_not_null($executor);
    $executor->init();
    
    my $result = $executor->execute("show tables");
    $self->assert_not_null($result);
    $self->assert_equals($result->status, 0);
    
    say(join(',',map{$_->[0]} @{$result->data}));
    
    $self->assert(-f $vardir."/mysql.pid") if not windows();
    $self->assert(-f $vardir."/mysql.err");

    $server->stopServer;

    sayFile($server->logfile);

    $server = GenTest::Server::MySQLd->new(basedir => $ENV{RQG_MYSQL_BASE},
                                           vardir => $vardir,
                                           port => $portbase,
                                           start_dirty => 1);
    
    $self->assert_not_null($server);
    $server->startServer;
    push @pids,$server->serverpid;
    $server->stopServer;

    sayFile($server->logfile);
}

1;
