# Copyright (c) 2010, 2012, Oracle and/or its affiliates. All rights reserved.
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

package DBServer::MySQL::ReplMySQLd;

@ISA = qw(DBServer::DBServer);

use DBI;
use DBServer::DBServer;
use DBServer::MySQL::MySQLd;
use if osWindows(), Win32::Process;
use Time::HiRes;

use strict;

use Carp;
use Data::Dumper;
use GenTest::ReplicationTerms qw(replicationTerms);

use constant REPLMYSQLD_BASEDIR => 0;
use constant REPLMYSQLD_SOURCE_VARDIR => 1;
use constant REPLMYSQLD_REPLICA_VARDIR => 2;
use constant REPLMYSQLD_SOURCE_PORT => 3;
use constant REPLMYSQLD_REPLICA_PORT => 4;
use constant REPLMYSQLD_MODE => 5;
use constant REPLMYSQLD_START_DIRTY => 6;
use constant REPLMYSQLD_SERVER_OPTIONS => 7;
use constant REPLMYSQLD_SOURCE => 8;
use constant REPLMYSQLD_REPLICA => 9;
use constant REPLMYSQLD_VALGRIND => 10;
use constant REPLMYSQLD_VALGRIND_OPTIONS => 11;
use constant REPLMYSQLD_GENERAL_LOG => 12;
use constant REPLMYSQLD_DEBUG_SERVER => 13;
use constant REPLMYSQLD_TERMS => 14;

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({'source' => REPLMYSQLD_SOURCE,
                                   'replica' => REPLMYSQLD_REPLICA,
                                   'basedir' => REPLMYSQLD_BASEDIR,
                                   'debug_server' => REPLMYSQLD_DEBUG_SERVER,
                                   'source_vardir' => REPLMYSQLD_SOURCE_VARDIR,
                                   'source_port' => REPLMYSQLD_SOURCE_PORT,
                                   'replica_vardir' => REPLMYSQLD_REPLICA_VARDIR,
                                   'replica_port' => REPLMYSQLD_REPLICA_PORT,
                                   'mode' => REPLMYSQLD_MODE,
                                   'server_options' => REPLMYSQLD_SERVER_OPTIONS,
                                   'general_log' => REPLMYSQLD_GENERAL_LOG,
                                   'start_dirty' => REPLMYSQLD_START_DIRTY,
                                   'valgrind' => REPLMYSQLD_VALGRIND,
                                   'valgrind_options', REPLMYSQLD_VALGRIND_OPTIONS},@_);

    if (defined $self->source || defined $self->replica) {
        ## Repl pair defined from two predefined servers

        if (not (defined $self->source && defined $self->replica)) {
            croak("Both source and replica must be defined");
        }
        $self->source->addServerOptions(["--server_id=1",
                                         "--log-bin=mysql-bin",
                                         "--report-host=127.0.0.1",
                                         "--report_port=".$self->source->port]);
        $self->replica->addServerOptions(["--server_id=2",
                                        "--report-host=127.0.0.1",
                                        "--report_port=".$self->replica->port]);
    } else {
        ## Repl pair defined from parameters. The servers have the same basedir (is of the same version)
        if (not defined $self->[REPLMYSQLD_SOURCE_PORT]) {
            $self->[REPLMYSQLD_SOURCE_PORT] = DBServer::MySQL::MySQLd::MYSQLD_DEFAULT_PORT;
        }

        if (not defined $self->[REPLMYSQLD_REPLICA_PORT]) {
            $self->[REPLMYSQLD_REPLICA_PORT] = $self->[REPLMYSQLD_SOURCE_PORT] + 2;
        }

        if (not defined $self->[REPLMYSQLD_MODE]) {
            $self->[REPLMYSQLD_MODE] = 'default';
        }

        if (not defined $self->[REPLMYSQLD_SOURCE_VARDIR]) {
            $self->[REPLMYSQLD_SOURCE_VARDIR] = "mysql-test/var";
        }
        if (not defined $self->[REPLMYSQLD_REPLICA_VARDIR]) {
            my $varbase = $self->[REPLMYSQLD_SOURCE_VARDIR];
            $varbase =~ s/(.*)\/$/\1/;
            $self->[REPLMYSQLD_REPLICA_VARDIR] = $varbase.'_slave';
        }

        my @source_options;
        push(@source_options,
             "--server_id=1",
             "--log-bin=mysql-bin",
             "--report-host=127.0.0.1",
             "--report_port=".$self->[REPLMYSQLD_SOURCE_PORT]);
        if (defined $self->[REPLMYSQLD_SERVER_OPTIONS]) {
            push(@source_options,
                 @{$self->[REPLMYSQLD_SERVER_OPTIONS]});
        }


        $self->[REPLMYSQLD_SOURCE] =
        DBServer::MySQL::MySQLd->new(basedir => $self->[REPLMYSQLD_BASEDIR],
                                     vardir => $self->[REPLMYSQLD_SOURCE_VARDIR],
                                     debug_server => $self->[REPLMYSQLD_DEBUG_SERVER],
                                     port => $self->[REPLMYSQLD_SOURCE_PORT],
                                     server_options => \@source_options,
                                     general_log => $self->[REPLMYSQLD_GENERAL_LOG],
                                     start_dirty => $self->[REPLMYSQLD_START_DIRTY],
                                     valgrind => $self->[REPLMYSQLD_VALGRIND],
                                     valgrind_options => $self->[REPLMYSQLD_VALGRIND_OPTIONS]);

        if (not defined $self->source) {
            croak("Could not create source");
        }

        my @replica_options;
        push(@replica_options,
             "--server_id=2",
             "--report-host=127.0.0.1",
             "--report_port=".$self->[REPLMYSQLD_REPLICA_PORT]);
        if (defined $self->[REPLMYSQLD_SERVER_OPTIONS]) {
            push(@replica_options,
                 @{$self->[REPLMYSQLD_SERVER_OPTIONS]});
        }


        $self->[REPLMYSQLD_REPLICA] =
        DBServer::MySQL::MySQLd->new(basedir => $self->[REPLMYSQLD_BASEDIR],
                                     vardir => $self->[REPLMYSQLD_REPLICA_VARDIR],
                                     debug_server => $self->[REPLMYSQLD_DEBUG_SERVER],
                                     port => $self->[REPLMYSQLD_REPLICA_PORT],
                                     server_options => \@replica_options,
                                     general_log => $self->[REPLMYSQLD_GENERAL_LOG],
                                     start_dirty => $self->[REPLMYSQLD_START_DIRTY],
                                     valgrind => $self->[REPLMYSQLD_VALGRIND],
                                     valgrind_options => $self->[REPLMYSQLD_VALGRIND_OPTIONS]);

        if (not defined $self->replica) {
            $self->source->stopServer;
            croak("Could not create replica");
        }
    }

    return $self;
}

sub source {
    return $_[0]->[REPLMYSQLD_SOURCE];
}

sub replica {
    return $_[0]->[REPLMYSQLD_REPLICA];
}

sub mode {
    return $_[0]->[REPLMYSQLD_MODE];
}

sub startServer {
    my ($self) = @_;

    $self->source->startServer;
    my $source_dbh = $self->source->dbh;
    $self->replica->startServer;
    my $replica_dbh = $self->replica->dbh;

	my ($foo, $source_version) = $source_dbh->selectrow_array("SHOW VARIABLES LIKE 'version'");

	if (($source_version !~ m{^5\.0}sio) && ($self->mode ne 'default')) {
		$source_dbh->do("SET GLOBAL BINLOG_FORMAT = '".$self->mode."'");
		$replica_dbh->do("SET GLOBAL BINLOG_FORMAT = '".$self->mode."'");
	}

	my $terms = replicationTerms($source_version);
	$self->[REPLMYSQLD_TERMS] = $terms;

	$replica_dbh->do($terms->{stop_replica});

#	$replica_dbh->do("SET GLOBAL storage_engine = '$engine'") if defined $engine;

	$replica_dbh->do($terms->{change_source}.
                   " ".$terms->{source_port}." = ".$self->source->port.",".
                   " ".$terms->{source_host}." = '127.0.0.1',".
                   " ".$terms->{source_user}." = 'root',".
                   " ".$terms->{source_connect_retry}." = 1");

	$replica_dbh->do($terms->{start_replica});

    return DBSTATUS_OK;
}

sub waitForReplicaSync {
    my ($self) = @_;
    # Fall back to legacy only if startServer() never ran (should be rare).
    my $terms = $self->[REPLMYSQLD_TERMS] || replicationTerms(undef);

    # A reporter such as "Shutdown" can legitimately terminate the servers
    # as its own coverage check before GenTest::App::GenTest returns, and
    # runall-new.pl's post-run source/replica comparison calls this
    # unconditionally whenever --rpl_mode is set, with no way to know that
    # already happened. Fail clearly rather than crashing the whole process
    # on ->selectrow_array against an undef/disconnected dbh.
    my $source_dbh = $self->source->dbh;
    if (not defined $source_dbh) {
        say("waitForReplicaSync: source connection is gone (server already stopped?), cannot compare.");
        return DBSTATUS_FAILURE;
    }

    my ($file, $pos) = $source_dbh->selectrow_array($terms->{binlog_status});
    say("source status $file/$pos");

    my $replica_dbh = $self->replica->dbh;
    if (not defined $replica_dbh) {
        say("waitForReplicaSync: replica connection is gone (server already stopped?), cannot compare.");
        return DBSTATUS_FAILURE;
    }

    my $wait_result = $replica_dbh->selectrow_array("SELECT ".$terms->{pos_wait_func}."('$file',$pos)");
    if (not defined $wait_result) {
        my $replica_status = $replica_dbh->selectrow_hashref($terms->{replica_status});
        my $err = (defined $replica_status)
            ? ($replica_status->{Last_SQL_Error} || $replica_status->{Last_Error} || '')
            : '';
        say("Replica SQL thread has stopped with error: ".$err);
		return DBSTATUS_FAILURE;
    } else {
        return DBSTATUS_OK;
    }
}

sub stopServer {
    my ($self) = @_;
    my $terms = $self->[REPLMYSQLD_TERMS] || replicationTerms(undef);

    $self->waitForReplicaSync();
    # Same rationale as the guards in waitForReplicaSync(): a prior reporter
    # (e.g. "Shutdown") may have already stopped the replica.
    my $replica_dbh = $self->replica->dbh;
    $replica_dbh->do($terms->{stop_replica}) if defined $replica_dbh;

    $self->replica->stopServer;
    $self->source->stopServer;

    return DBSTATUS_OK;
}

1;
