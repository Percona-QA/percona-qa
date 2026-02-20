#!/usr/bin/perl

# Copyright (c) 2008,2012 Oracle and/or its affiliates. All rights reserved.
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

package GenTest::App::GenTest;

@ISA = qw(GenTest);

use strict;
use Carp;
use Data::Dumper;
use File::Basename;
use File::Path 'mkpath';
use File::Copy;
use File::Spec;
use Cwd;

use GenTest;
use GenTest::Properties;
use GenTest::Constants;
use GenTest::App::Gendata;
use GenTest::App::GendataSimple;
use GenTest::IPC::Channel;
use GenTest::IPC::Process;
use GenTest::ErrorFilter;
use GenTest::Grammar;

use POSIX;
use Time::HiRes;

use GenTest::XML::Report;
use GenTest::XML::Test;
use GenTest::XML::BuildInfo;
use GenTest::XML::Transporter;
use GenTest::Constants;
use GenTest::Result;
use GenTest::Validator;
use GenTest::Executor;
use GenTest::Mixer;
use GenTest::Reporter;
use GenTest::ReporterManager;
use GenTest::Filter::Regexp;
use GenTest::Incident;

use constant PROCESS_TYPE_PARENT	=> 0;
use constant PROCESS_TYPE_PERIODIC	=> 1;
use constant PROCESS_TYPE_CHILD		=> 2;

use constant GT_CONFIG => 0;
use constant GT_XML_TEST => 3;
use constant GT_XML_REPORT => 4;
use constant GT_CHANNEL => 5;

use constant GT_GRAMMAR => 6;
use constant GT_GENERATOR => 7;
use constant GT_REPORTER_MANAGER => 8;
use constant GT_TEST_START => 9;
use constant GT_TEST_END => 10;
use constant GT_QUERY_FILTERS => 11;
use constant GT_LOG_FILES_TO_REPORT => 12;

sub new {
    my $class = shift;

    my $self = $class->SUPER::new({
        'config' => GT_CONFIG},@_);

    croak ("Need config") if not defined $self->config;

    return $self;
}

sub config {
    return $_[0]->[GT_CONFIG];
}

sub grammar {
    return $_[0]->[GT_GRAMMAR];
}

sub generator {
    return $_[0]->[GT_GENERATOR];
}

sub XMLTest {
    return $_[0]->[GT_XML_TEST];
}

sub XMLReport {
    return $_[0]->[GT_XML_REPORT];
}

sub channel {
    return $_[0]->[GT_CHANNEL];
}

sub reporterManager {
    return $_[0]->[GT_REPORTER_MANAGER];
}

sub queryFilters {
    return $_[0]->[GT_QUERY_FILTERS];
}

sub logFilesToReport {
    return @{$_[0]->[GT_LOG_FILES_TO_REPORT]};
}

sub run {
    my $self = shift;

    $SIG{TERM} = sub { exit(0) };
    $SIG{CHLD} = "IGNORE" if osWindows();
    $SIG{INT} = "IGNORE";

    if (defined $ENV{RQG_HOME}) {
        $ENV{RQG_HOME} = osWindows() ? $ENV{RQG_HOME}.'\\' : $ENV{RQG_HOME}.'/';
    }

    $ENV{RQG_DEBUG} = 1 if $self->config->debug;

    $self->initSeed();

    my $queries = $self->config->queries;
    $queries =~ s{K}{000}so;
    $queries =~ s{M}{000000}so;
    $self->config->property('queries', $queries);

    say("-------------------------------\nConfiguration");
    $self->config->printProps;

    my $gendata_result = $self->doGenData();
    return $gendata_result if $gendata_result != STATUS_OK;

    my $post_gendata_result = $self->doPostGendataSQL();
    return $post_gendata_result if $post_gendata_result != STATUS_OK;

    $self->[GT_TEST_START] = time();
    $self->[GT_TEST_END] = $self->[GT_TEST_START] + $self->config->duration;

    $self->[GT_CHANNEL] = GenTest::IPC::Channel->new();

    my $init_generator_result = $self->initGenerator();
    return $init_generator_result if $init_generator_result != STATUS_OK;

    my $init_reporters_result = $self->initReporters();
    return $init_reporters_result if $init_reporters_result != STATUS_OK;

    my $init_validators_result = $self->initValidators();
    return $init_validators_result if $init_validators_result != STATUS_OK;

    # Cache metadata and other info that may be needed later
    my @log_files_to_report;
    foreach my $i (0..2) {
        next if $self->config->dsn->[$i] eq '';
        next if $self->config->dsn->[$i] !~ m{mysql}sio;
        my $metadata_executor = GenTest::Executor->newFromDSN($self->config->dsn->[$i], osWindows() ? undef : $self->channel());
        $metadata_executor->init();
        $metadata_executor->cacheMetaData() if defined $metadata_executor->dbh();

        # Cache log file names needed for result reporting at end-of-test

        # We do not copy the general log, as it may grow very large for some tests.
        #my $logfile_result = $metadata_executor->execute("SHOW VARIABLES LIKE 'general_log_file'");
        #push(@log_files_to_report, $logfile_result->data()->[0]->[1]);

        # Guessing the error log file name relative to datadir (lacking safer methods).
        my $datadir_result = $metadata_executor->execute("SHOW VARIABLES LIKE 'datadir'");
        my $errorlog;
        foreach my $errorlog_path (
            "../log/master.err",  # MTRv1 regular layout
            "../log/mysqld1.err", # MTRv2 regular layout
            "../mysql.err"        # DBServer::MySQL layout
        ) {
            my $possible_path = File::Spec->catfile($datadir_result->data()->[0]->[1], $errorlog_path);
            if (-e $possible_path) {
                $errorlog = $possible_path;
                last;
            }
        }
        push(@log_files_to_report, $errorlog) if defined $errorlog;

        $metadata_executor->disconnect();
        undef $metadata_executor;
    }

    $self->[GT_LOG_FILES_TO_REPORT] = \@log_files_to_report;

    if (defined $self->config->filter) {
       $self->[GT_QUERY_FILTERS] = [ GenTest::Filter::Regexp->new(
           file => $self->config->filter
       ) ];
    }

    say("Starting ".$self->config->threads." processes, ".
        $self->config->queries." queries each, duration ".
        $self->config->duration." seconds.");

    $self->initXMLReport();

    ### Start central reporting thread ####

    my $errorfilter = GenTest::ErrorFilter->new(channel => $self->channel());
    my $errorfilter_p = GenTest::IPC::Process->new(object => $errorfilter);
    if (!osWindows()) {
        $errorfilter_p->start();
    }

    my $reporter_pid = $self->reportingProcess();

    ### Start worker children ###

    my %worker_pids;

    if ($self->config->threads > 0) {
        foreach my $worker_id (1..$self->config->threads) {
            my $worker_pid = $self->workerProcess($worker_id);
            $worker_pids{$worker_pid} = 1;
            Time::HiRes::sleep(0.1); # fork slowly for more predictability
        }
    }

    ### Main process

    if (osWindows()) {
        ## Important that this is done here in the parent after the last
        ## fork since on windows Process.pm uses threads
        $errorfilter_p->start();
    }

    # We are the parent process, wait for for all spawned processes to terminate
    my $total_status = STATUS_OK;
    my $reporter_died = 0;

    ## Parent thread does not use channel
    $self->channel()->close;

    # Worker & Reporter processes that were spawned.
    my @spawned_pids = (keys %worker_pids, $reporter_pid);

    OUTER: while (1) {
        # Wait for processes to complete, i.e only processes spawned by workers & reporters.
        foreach my $spawned_pid (@spawned_pids) {
            my $child_pid = waitpid($spawned_pid, 0);
            my $child_exit_status = $? > 0 ? ($? >> 8) : 0;

            $total_status = $child_exit_status if $child_exit_status > $total_status;

            if ($child_pid == $reporter_pid) {
                $reporter_died = 1;
                last OUTER;
            } else {
                delete $worker_pids{$child_pid};
            }

            last OUTER if $child_exit_status >= STATUS_CRITICAL_FAILURE;
            last OUTER if keys %worker_pids == 0;
            last OUTER if $child_pid == -1;
        }
    }

    foreach my $worker_pid (keys %worker_pids) {
        say("Killing remaining worker process with pid $worker_pid...");
        kill(15, $worker_pid);
    }

    if ($reporter_died == 0) {
        # Wait for periodic process to return the status of its last execution
        Time::HiRes::sleep(1);
        say("Killing periodic reporting process with pid $reporter_pid...");
        kill(15, $reporter_pid);

        if (osWindows()) {
            # We use sleep() + non-blocking waitpid() due to a bug in ActiveState Perl
            Time::HiRes::sleep(1);
            waitpid($reporter_pid, &POSIX::WNOHANG() );
        } else {
            waitpid($reporter_pid, 0);
        }

        if ($? > -1 ) {
            my $reporter_status = $? > 0 ? $? >> 8 : 0;
            $total_status = $reporter_status if $reporter_status > $total_status;
        }
    }

    $errorfilter_p->kill();

    return $self->reportResults($total_status);

}

sub reportResults {
    my ($self, $total_status) = @_;

    my $reporter_manager = $self->reporterManager();
    my @report_results;

    # New report type REPORTER_TYPE_END, used with reporter's that processes information at the end of a test.
    if ($total_status == STATUS_OK) {
        @report_results = $reporter_manager->report(REPORTER_TYPE_SUCCESS | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif (
        ($total_status == STATUS_LENGTH_MISMATCH) ||
        ($total_status == STATUS_CONTENT_MISMATCH)
    ) {
        @report_results = $reporter_manager->report(REPORTER_TYPE_DATA | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif ($total_status == STATUS_SERVER_CRASHED) {
        say("Server crash reported, initiating post-crash analysis...");
        @report_results = $reporter_manager->report(REPORTER_TYPE_CRASH | REPORTER_TYPE_ALWAYS);
    } elsif ($total_status == STATUS_SERVER_DEADLOCKED) {
        say("Server deadlock reported, initiating analysis...");
        @report_results = $reporter_manager->report(REPORTER_TYPE_DEADLOCK | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } elsif ($total_status == STATUS_SERVER_KILLED) {
        @report_results = $reporter_manager->report(REPORTER_TYPE_SERVER_KILLED | REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    } else {
        @report_results = $reporter_manager->report(REPORTER_TYPE_ALWAYS | REPORTER_TYPE_END);
    }

    my $report_status = shift @report_results;
    $total_status = $report_status if $report_status > $total_status;
    $total_status = STATUS_OK if $total_status == STATUS_SERVER_KILLED;

    $self->reportXMLIncidents($total_status, \@report_results);

    if ($total_status == STATUS_OK) {
        say("Test completed successfully.");
        return STATUS_OK;
    } else {
        say("Test completed with failure status ".status2text($total_status)." ($total_status)");
        return $total_status;
    }
}

sub stopChild {
    my ($self, $status) = @_;

    croak "calling stopChild() without a \$status" if not defined $status;

    if (osWindows()) {
        exit $status;
    } else {
        safe_exit($status);
    }
}

sub reportingProcess {
    my $self = shift;

    my $reporter_pid = fork();

    if ($reporter_pid != 0) {
        return $reporter_pid;
    }

    my $reporter_killed = 0;
    local $SIG{TERM} = sub { $reporter_killed = 1 };

    ## Reporter process does not use channel
    $self->channel()->close();

    Time::HiRes::sleep(($self->config->threads + 1) / 10);
    say("Started periodic reporting process...");

    while (1) {
        my $reporter_status = $self->reporterManager()->monitor(REPORTER_TYPE_PERIODIC);
        $self->stopChild($reporter_status) if $reporter_status > STATUS_CRITICAL_FAILURE;
        last if $reporter_killed == 1;
        sleep(10);
    }

    $self->stopChild(STATUS_OK);
}

sub workerProcess {
    my ($self, $worker_id) = @_;

    my $worker_pid = fork();
    $self->channel()->writer;

    if ($worker_pid != 0) {
        return $worker_pid;
    }

    $| = 1;
    my $ctrl_c = 0;
    local $SIG{INT} = sub { $ctrl_c = 1 };

    $self->generator()->setSeed($self->config->seed() + $worker_id);
    $self->generator()->setThreadId($worker_id);

    my @executors;
    foreach my $i (0..2) {
        next if $self->config->dsn->[$i] eq '';
        my $executor = GenTest::Executor->newFromDSN($self->config->dsn->[$i], osWindows() ? undef : $self->channel());
        $executor->sqltrace($self->config->sqltrace);
        $executor->setId($i+1);
        push @executors, $executor;
    }

    my $mixer = GenTest::Mixer->new(
        generator => $self->generator(),
        executors => \@executors,
        validators => $self->config->validators,
        properties =>  $self->config,
        filters => $self->queryFilters(),
	end_time => $self->[GT_TEST_END]
    );

    $self->stopChild(STATUS_ENVIRONMENT_FAILURE) if not defined $mixer;

    my $worker_result = 0;

    foreach my $i (1..$self->config->queries) {
        my $query_result = $mixer->next();
        if ($query_result > STATUS_CRITICAL_FAILURE) {
            undef $mixer;	# so that destructors are called
            $self->stopChild($query_result);
        }

        $worker_result = $query_result if $query_result > $worker_result && $query_result > STATUS_TEST_FAILURE;
        last if $query_result == STATUS_EOF;
        last if $ctrl_c == 1;
        last if time() > $self->[GT_TEST_END];
    }

    foreach my $executor (@executors) {
        $executor->disconnect;
        undef $executor;
    }

    # Forcefully deallocate the Mixer so that Validator destructors are called
    undef $mixer;
    undef $self->[GT_QUERY_FILTERS];

    if ($worker_result > 0) {
        say("Child worker process completed with error code $worker_result.");
        $self->stopChild($worker_result);
    } else {
        say("Child worker process completed successfully.");
        $self->stopChild(STATUS_OK);
    }
}

sub doGenData {
    my $self = shift;

    return STATUS_OK if not defined $self->config->gendata();
    return STATUS_OK if defined $self->config->property('start-dirty');

    my $i = -1;
    foreach my $dsn (@{$self->config->dsn}) {
        $i++;
        next if $dsn eq '';
        my $gendata_result;
        if ($self->config->gendata eq '') {
            $gendata_result = GenTest::App::GendataSimple->new(
               dsn => $dsn,
               views => ${$self->config->views}[$i],
               engine => $self->config->engine,
               sqltrace=> $self->config->sqltrace,
               notnull => $self->config->notnull,
               rows => $self->config->rows,
               varchar_length => $self->config->property('varchar-length')
            )->run();
        } else {
            $gendata_result = GenTest::App::Gendata->new(
               spec_file => $self->config->gendata,
               dsn => $dsn,
               engine => $self->config->engine,
               seed => $self->config->seed(),
               debug => $self->config->debug,
               rows => $self->config->rows,
               views => ${$self->config->views}[$i],
               varchar_length => $self->config->property('varchar-length'),
               sqltrace => $self->config->sqltrace,
               short_column_names => $self->config->short_column_names,
               strict_fields => $self->config->strict_fields,
               notnull => $self->config->notnull
            )->run();
        }

        return $gendata_result if $gendata_result > STATUS_OK;

        # For multi-master setup, e.g. Galera, we only need to do generatoion once
        return STATUS_OK if $self->config->property('multi-master');
    }

    return STATUS_OK;
}

sub _extractDSNInfo {
    my ($self, $dsn) = @_;

    # Parse DSN format: dbi:mysql:host=127.0.0.1:port=19300:user=root:database=test
    # Also handle socket connections: dbi:mysql:host=127.0.0.1:port=19300:mysql_socket=/tmp/socket.sock
    my %info = ();

    if ($dsn =~ /dbi:mysql:/i) {
        # Extract host
        if ($dsn =~ /:host=([^:]+)/i) {
            $info{host} = $1;
        }

        # Extract port
        if ($dsn =~ /:port=([^:]+)/i) {
            $info{port} = $1;
        }

        # Extract user
        if ($dsn =~ /:user=([^:]+)/i) {
            $info{user} = $1;
        }

        # Extract database
        if ($dsn =~ /:database=([^:]+)/i) {
            $info{database} = $1;
        }

        # Extract socket (mysql_socket parameter)
        if ($dsn =~ /:mysql_socket=([^:]+)/i) {
            $info{socket} = $1;
        }

        # Extract password if present (for completeness, though RQG typically uses root with no password)
        if ($dsn =~ /:password=([^:]+)/i) {
            $info{password} = $1;
        }
    } else {
        return undef;  # Not a MySQL DSN
    }

    return \%info;
}

sub _findMySQLClient {
    my $self = shift;

    # Try to get basedir from RQG_MYSQL_BASE environment variable first
    my $basedir;
    if (defined $ENV{RQG_MYSQL_BASE}) {
        $basedir = $ENV{RQG_MYSQL_BASE};
    } else {
        # Try to get basedir from config if available (wrapper scripts may pass it via config)
        if (defined $self->config && defined $self->config->property('basedir')) {
            $basedir = $self->config->property('basedir');
        }
    }

    # If basedir is available, use MySQLd.pm's _find method (same as lines 118-120 and 144-146)
    if (defined $basedir) {
        require DBServer::MySQL::MySQLd;

        # Create a minimal MySQLd object to use its _find method
        my $mysql_client;
        eval {
            my $mysqld = DBServer::MySQL::MySQLd->new(
                basedir => $basedir,
                start_dirty => 1  # Skip database initialization
            );

            # Use the same _find pattern as MySQLd.pm uses for mysqldump (lines 144-146)
            my @search_paths = osWindows()
                ? ("client/Debug", "client/RelWithDebInfo", "client/Release", "bin")
                : ("client", "bin");
            my $mysql_binary = osWindows() ? "mysql.exe" : "mysql";

            $mysql_client = $mysqld->_find(
                [$mysqld->basedir],
                \@search_paths,
                $mysql_binary
            );
        };

        # If _find croaks or fails, $mysql_client will be undef
        if ($@) {
            $mysql_client = undef;
        }

        if (defined $mysql_client && -f $mysql_client && -x $mysql_client) {
            say("DEBUG: Found mysql client: $mysql_client") if rqg_debug();
            return $mysql_client;
        }
    }

    say("WARNING: Could not find mysql client binary");
    return undef;
}

sub doPostGendataSQL {
    my $self = shift;

    return STATUS_OK if not defined $self->config->property('post-gendata-sql');
    return STATUS_OK if defined $self->config->property('start-dirty');

    my $sql_file = $self->config->property('post-gendata-sql');

    # Check if file exists
    if (not -e $sql_file) {
        say("ERROR: Post-gendata SQL file not found: $sql_file");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    # Resolve absolute path
    my $abs_sql_file = File::Spec->rel2abs($sql_file);

    say("Executing post-gendata SQL from file: $abs_sql_file");

    # Find MySQL client binary
    my $mysql_client = $self->_findMySQLClient();
    if (not defined $mysql_client) {
        say("ERROR: Could not find mysql client binary");
        return STATUS_ENVIRONMENT_FAILURE;
    }

    my $i = -1;
    foreach my $dsn (@{$self->config->dsn}) {
        $i++;
        next if $dsn eq '';

        # Extract connection info from DSN
        my $dsn_info = $self->_extractDSNInfo($dsn);
        if (not defined $dsn_info) {
            say("ERROR: Failed to parse DSN: $dsn");
            return STATUS_ENVIRONMENT_FAILURE;
        }

        # Build mysql client command arguments
        my @mysql_args = (
            '--user=' . ($dsn_info->{user} || 'root'),
            '--force',      # Continue on errors
            '--binary-mode', # Handle binary data
            '--silent'       # Suppress query results (only show errors/warnings)
        );

        # Add password (RQG typically uses root with no password)
        push @mysql_args, '--password=' . ($dsn_info->{password} || '');

        # Determine connection method (socket preferred over host/port)
        my $socket_path;
        if (defined $dsn_info->{socket} && -S $dsn_info->{socket}) {
            $socket_path = $dsn_info->{socket};
        } elsif (defined $dsn_info->{port}) {
            # Check standard socket locations
            for my $sock (
                "/tmp/RQGmysql." . $dsn_info->{port} . ".sock",
                "/var/run/mysqld/mysqld.sock",
                "/tmp/mysql.sock"
            ) {
                if (-S $sock) {
                    $socket_path = $sock;
                    last;
                }
            }
        }

        if ($socket_path) {
            push @mysql_args, '--socket=' . $socket_path;
        } else {
            push @mysql_args, '--host=' . ($dsn_info->{host} || '127.0.0.1');
            push @mysql_args, '--port=' . ($dsn_info->{port} || '3306');
        }

        # Add database if specified (optional - can be set in SQL file with USE)
        push @mysql_args, '--database=' . $dsn_info->{database} if defined $dsn_info->{database};

        # Get basedir (build directory) - needed for out-of-source builds
        # Components need to be found relative to the build directory
        my $basedir;
        if (defined $ENV{RQG_MYSQL_BASE}) {
            $basedir = $ENV{RQG_MYSQL_BASE};
        } elsif (defined $self->config && defined $self->config->property('basedir')) {
            $basedir = $self->config->property('basedir');
        }

        # Add --plugin-dir to mysql client if basedir is available and plugin directory exists
        # This helps with component installation in out-of-source builds
        if (defined $basedir && -d $basedir) {
            my $plugin_dir = File::Spec->catdir($basedir, "lib", "plugin");
            $plugin_dir = File::Spec->rel2abs($plugin_dir);
            if (-d $plugin_dir) {
                push @mysql_args, '--plugin-dir=' . $plugin_dir;
                say("DEBUG: Added --plugin-dir=$plugin_dir to mysql client command") if rqg_debug();
            }
        }

        # Get SQL file directory for SOURCE command path resolution
        my $sql_file_dir = dirname($abs_sql_file);

        # Build command array
        my @mysql_cmd_array = ($mysql_client, @mysql_args);

        # Change to SQL file's directory so SOURCE commands with relative paths work correctly
        my $original_dir = Cwd::getcwd();
        chdir($sql_file_dir) or do {
            say("WARNING: Could not change to directory '$sql_file_dir', continuing anyway");
        };

        # Pre-process SQL file to handle SOURCE commands
        # Parse SOURCE commands and inline the content to avoid mysql readline buffer limits
        my $processed_sql_content = $self->_processSQLFileWithSources($abs_sql_file, {});
        if (not defined $processed_sql_content) {
            say("ERROR: Failed to process SQL file with SOURCE commands");
            chdir($original_dir) if defined $original_dir;
            return STATUS_ENVIRONMENT_FAILURE;
        }

        # Write processed SQL to a temporary file
        my $temp_sql_file = File::Spec->catfile($sql_file_dir, ".rqg_post_gendata_$$.sql");
        open(my $temp_fh, '>', $temp_sql_file) or do {
            say("ERROR: Unable to create temporary SQL file '$temp_sql_file': $!");
            chdir($original_dir) if defined $original_dir;
            return STATUS_ENVIRONMENT_FAILURE;
        };
        print $temp_fh $processed_sql_content;
        close($temp_fh);

        # Handle sqltrace if enabled - cache SQL splitting results to avoid redundant operations
        my $sqltrace_enabled = $self->config->sqltrace;
        my @statements = ();
        my @sql_lines = ();
        my %delimiter_lines = ();

        if ($sqltrace_enabled) {
            # Split SQL into statements once and cache the result
            @statements = $self->_splitSQLStatementsSimple($processed_sql_content);
            # Cache split lines for processed SQL content
            @sql_lines = split(/\n/, $processed_sql_content);

            # Pre-filter statements once to avoid repeated regex checks
            @statements = grep { $_ !~ /^\s*$/ && $_ !~ /^\s*DELIMITER\s+/i } @statements;

            # Build delimiter lines hash for O(1) lookup
            my $line_num = 1;
            foreach my $line (@sql_lines) {
                my $line_trimmed = $line;
                $line_trimmed =~ s/^\s+|\s+$//g;
                if ($line_trimmed =~ /^DELIMITER\s+/i) {
                    $delimiter_lines{$line_num} = 1;
                }
                $line_num++;
            }
        }

        # Handle sqltrace if enabled (non-MarkErrors mode logs before execution)
        if ($sqltrace_enabled && $sqltrace_enabled ne 'MarkErrors') {
            # Use cached @statements instead of re-splitting
            foreach my $statement (@statements) {

                # Clean up statement - remove any trailing delimiters (|, ;, etc.)
                $statement =~ s/[|;]\s*$//;

                # Format query for sqltrace (exactly like executor does)
                my $trace_query;
                if ($statement =~ m{(procedure|function)}sgio) {
                    my $stmt_clean = $statement;
                    $stmt_clean =~ s/\$\$;/\$\$|/g;
                    $trace_query = "DELIMITER |\n$stmt_clean|\nDELIMITER ";
                } else {
                    $trace_query = $statement;
                }

                print "$trace_query;\n";
            }
        }

        # Execute mysql client with file input redirection
        # Use simple shell redirection: mysql [args] < file.sql 2>&1
        # The --silent flag suppresses query results, so we only get errors/warnings

        # Build command with proper quoting to avoid shell injection
        my $cmd_str = join(' ', map {
            my $arg = $_;
            # Quote arguments containing spaces or special shell characters
            ($arg =~ /[^\w=\-\/\.]/) ? do {
                $arg =~ s/'/'"'"'/g;  # Escape single quotes for shell
                "'$arg'";
            } : $arg;
        } @mysql_cmd_array);

        # Add file redirection: < temp_file 2>&1 to capture stderr
        $cmd_str .= " < " . quotemeta($temp_sql_file) . " 2>&1";

        # Execute command and capture output (stderr redirected to stdout)
        my $output = `$cmd_str`;
        my $exit_code = $? >> 8;

        # Parse output for errors and handle sqltrace MarkErrors mode
        if ($sqltrace_enabled && $sqltrace_enabled eq 'MarkErrors') {
            # Parse mysql output for errors - collect error messages with line numbers
            my @error_lines = split(/\n/, $output);
            my @errors = ();
            foreach my $line (@error_lines) {
                if ($line =~ /^ERROR\s+(\d+)\s+\([^)]+\)\s+at\s+line\s+(\d+):/i) {
                    push @errors, { errno => $1, line => $2 };
                }
            }

            # Use cached @statements and @sql_lines instead of recomputing
            my %line_to_stmt = ();  # Maps line number (1-based) to statement index

            # For each statement, find its position in the SQL content
            # and map all lines in that range to the statement index
            # Use cached @statements (already filtered)
            my $stmt_idx = 0;
            my $search_pos = 0;
            foreach my $statement (@statements) {
                # Get first significant line of statement for matching
                my @stmt_lines = split(/\n/, $statement);
                my $first_line = $stmt_lines[0];
                $first_line =~ s/^\s+|\s+$//g;
                next if $first_line eq '';

                # Find this line in the SQL content (starting from where we left off)
                my $found_pos = index($processed_sql_content, $first_line, $search_pos);
                if ($found_pos != -1) {
                    # Calculate line number
                    my $before_match = substr($processed_sql_content, 0, $found_pos);
                    my $stmt_start_line = ($before_match =~ tr/\n/\n/) + 1;

                    # Count lines in this statement (approximate)
                    my $stmt_line_count = @stmt_lines;
                    # Add some buffer for multi-line statements and delimiter lines
                    my $stmt_end_line = $stmt_start_line + $stmt_line_count + 5;

                    # Map all lines in this range to this statement index
                    # But skip DELIMITER lines using O(1) hash lookup
                    for (my $l = $stmt_start_line; $l <= $stmt_end_line && $l <= @sql_lines; $l++) {
                        # Skip if this is a DELIMITER line (O(1) lookup instead of O(n) search)
                        if (!exists $delimiter_lines{$l}) {
                            $line_to_stmt{$l} = $stmt_idx;
                        }
                    }

                    $search_pos = $found_pos + length($first_line);
                }
                $stmt_idx++;
            }

            # Build error_statements map: statement index -> error number
            # Be conservative: only mark if error line maps to a statement
            my %error_statements = ();
            foreach my $error (@errors) {
                my $error_line = $error->{line};
                if (exists $line_to_stmt{$error_line}) {
                    my $err_stmt_idx = $line_to_stmt{$error_line};
                    # Only mark if not already marked (keep first error)
                    if (not exists $error_statements{$err_stmt_idx}) {
                        $error_statements{$err_stmt_idx} = $error->{errno};
                    }
                }
            }

            # Track statistics for debug output
            my $total_statements = @statements;
            my $failed_statements = 0;

            # Log all statements with error marking (statements are already pre-filtered)
            my $stmt_idx = 0;
            foreach my $statement (@statements) {
                $failed_statements++ if exists $error_statements{$stmt_idx};

                # Clean up statement - remove any trailing delimiters (|, ;, etc.)
                $statement =~ s/[|;]\s*$//;

                # Format query for sqltrace
                my $trace_query;
                if ($statement =~ m{(procedure|function)}sgio) {
                    # Convert $$; to $$| for DELIMITER format (in case there are any)
                    my $stmt_clean = $statement;
                    $stmt_clean =~ s/\$\$;/\$\$|/g;
                    $trace_query = "DELIMITER |\n$stmt_clean|\nDELIMITER ";
                } else {
                    $trace_query = $statement;
                }

                # Log with error prefix if this statement has an error
                if (exists $error_statements{$stmt_idx}) {
                    $trace_query =~ s/\n/\n# [sqltrace]    /g;
                    print '# [sqltrace] ERROR '.$error_statements{$stmt_idx}.": $trace_query;\n";
                } else {
                    print "$trace_query;\n";
                }
                $stmt_idx++;
            }

            # Print execution statistics if debug is enabled
            if (rqg_debug() && $total_statements > 0) {
                my $success_statements = $total_statements - $failed_statements;
                say("DEBUG: Post-gendata SQL execution: $total_statements statements executed, $success_statements succeeded, $failed_statements failed");
            }
        } elsif (rqg_debug() && $output) {
            # Print output only if debug is enabled (and not in MarkErrors mode)
            # With --silent flag, mysql only outputs errors/warnings, so print all output
            print $output;

            # Count statements and errors for statistics (non-MarkErrors mode)
            if ($sqltrace_enabled && $sqltrace_enabled ne 'MarkErrors') {
                # Use cached @statements (already filtered)
                my $total_statements = @statements;
                my @error_lines = grep { /^ERROR\s+\d+/i } split(/\n/, $output);
                my $failed_statements = @error_lines;
                my $success_statements = $total_statements - $failed_statements;
                say("DEBUG: Post-gendata SQL execution: $total_statements statements executed, $success_statements succeeded, $failed_statements failed");
            }
        }

        # Clean up temporary file
        unlink($temp_sql_file) if -e $temp_sql_file;

        # Restore original directory
        chdir($original_dir) if defined $original_dir;

        if ($exit_code != 0) {
            # MySQL client returns non-zero on errors, but --force allows continuation
            # Check if it's a connection error (exit code 1) vs SQL errors (exit code 1 but different)
            # For now, just log a warning and continue
            say("WARNING: MySQL client exited with code $exit_code for DSN: $dsn");
            # Don't fail the entire operation - --force flag allows continuation on SQL errors
            # Only fail on connection errors (which we can't easily distinguish)
        }

        # For multi-master setup, e.g. Galera, we only need to execute once
        return STATUS_OK if $self->config->property('multi-master');
    }

    return STATUS_OK;
}

sub _processSQLFileWithSources {
    my ($self, $sql_file, $visited) = @_;

    # Initialize visited files hash to prevent circular includes
    $visited = {} if not defined $visited;

    # Check if file exists
    if (not -e $sql_file) {
        say("ERROR: SQL file not found: $sql_file");
        return undef;
    }

    # Resolve absolute path
    my $abs_file = File::Spec->rel2abs($sql_file);

    # Check for circular includes
    if (exists $visited->{$abs_file}) {
        say("WARNING: Circular include detected for file: $abs_file, skipping");
        return '';
    }
    $visited->{$abs_file} = 1;

    # Read the file
    open(my $fh, '<', $abs_file) or do {
        say("ERROR: Unable to open SQL file '$abs_file': $!");
        return undef;
    };

    my @lines = <$fh>;
    close($fh);

    my $file_dir = dirname($abs_file);
    my @processed_lines;

    # Process each line, looking for SOURCE commands
    for (my $i = 0; $i < @lines; $i++) {
        my $line = $lines[$i];

        # Check for SOURCE command (case-insensitive, with optional semicolon)
        # Matches: SOURCE /path/to/file.sql; or SOURCE /path/to/file.sql
        # Also handles: \. /path/to/file.sql (alternative syntax)
        # Supports quoted paths: SOURCE '/path with spaces/file.sql'
        if ($line =~ /^\s*(?:SOURCE|source|\\.)\s+(['"]?)([^'";\n]+)\1\s*;?\s*$/i) {
            my $source_file = $2;
            $source_file =~ s/^\s+|\s+$//g;  # Trim whitespace

            # Resolve relative paths relative to current file's directory
            if (not File::Spec->file_name_is_absolute($source_file)) {
                $source_file = File::Spec->catfile($file_dir, $source_file);
            }
            $source_file = File::Spec->rel2abs($source_file);

            # Recursively process the SOURCE file
            my $source_content = $self->_processSQLFileWithSources($source_file, $visited);
            if (not defined $source_content) {
                say("ERROR: Failed to process SOURCE file: $source_file");
                return undef;
            }

            # Replace SOURCE line with the content of the sourced file
            # Add a newline before and after to maintain proper line structure
            push @processed_lines, $source_content;
            push @processed_lines, "\n" if $source_content ne '' && $source_content !~ /\n$/;
        } else {
            # Regular line, keep as-is
            push @processed_lines, $line;
        }
    }

    return join('', @processed_lines);
}

sub _splitSQLStatementsSimple {
    my ($self, $sql_content) = @_;

    # SQL statement splitting for sqltrace logging
    # Handles DELIMITER blocks, strings, and dollar-quoted blocks
    my @statements = ();
    my $current_statement = '';
    my $in_single_quote = 0;
    my $in_double_quote = 0;
    my $in_dollar_quote = 0;
    my $dollar_tag = '';
    my $current_delimiter = ';';
    my $prev_char = '';
    my @lines = split(/\n/, $sql_content);

    for (my $line_idx = 0; $line_idx < @lines; $line_idx++) {
        my $line = $lines[$line_idx];
        my $line_len = length($line);

        # Check for DELIMITER command at start of line
        if ($line =~ /^\s*DELIMITER\s+(\S+)\s*$/i || $line =~ /^\s*DELIMITER\s*$/i) {
            # Save current statement if any
            if ($current_statement =~ /\S/) {
                my $stmt = $current_statement;
                $stmt =~ s/^\s+|\s+$//g;
                if ($stmt ne '') {
                    push @statements, $stmt;
                }
                $current_statement = '';
            }

            # Update delimiter
            my $new_delimiter = $1 || ';';
            $current_delimiter = $new_delimiter;
            $in_single_quote = 0;
            $in_double_quote = 0;
            $in_dollar_quote = 0;
            $dollar_tag = '';
            $prev_char = '';
            next;  # Skip DELIMITER line
        }

        # Process line character by character
        for (my $i = 0; $i < $line_len; $i++) {
            my $char = substr($line, $i, 1);

            # Handle dollar-quoted strings ($$ ... $$)
            if (!$in_single_quote && !$in_double_quote && !$in_dollar_quote && $char eq '$') {
                # Look for matching $ to form tag
                my $next_dollar = index($line, '$', $i + 1);
                if ($next_dollar != -1) {
                    $dollar_tag = substr($line, $i, $next_dollar - $i + 1);
                    $in_dollar_quote = 1;
                    $current_statement .= $dollar_tag;
                    $i = $next_dollar;
                    $prev_char = '$';
                    next;
                }
            }

            if ($in_dollar_quote) {
                # Check if we hit the closing dollar tag
                if ($char eq '$' && $i + length($dollar_tag) - 1 < $line_len) {
                    my $possible_end = substr($line, $i, length($dollar_tag));
                    if ($possible_end eq $dollar_tag) {
                        $current_statement .= $dollar_tag;
                        $i += length($dollar_tag) - 1;
                        $in_dollar_quote = 0;
                        $dollar_tag = '';
                        $prev_char = '$';
                        next;
                    }
                }
                $current_statement .= $char;
                $prev_char = $char;
                next;
            }

            # Handle single quotes
            if (!$in_double_quote && $char eq "'") {
                # Check for escaped quote
                if ($prev_char eq '\\') {
                    my $backslash_count = 0;
                    my $check_pos = $i - 1;
                    while ($check_pos >= 0 && substr($line, $check_pos, 1) eq '\\') {
                        $backslash_count++;
                        $check_pos--;
                    }
                    if ($backslash_count % 2 == 1) {
                        $current_statement .= $char;
                        $prev_char = $char;
                        next;
                    }
                }
                $in_single_quote = !$in_single_quote;
                $current_statement .= $char;
                $prev_char = $char;
                next;
            }

            # Handle double quotes
            if (!$in_single_quote && $char eq '"') {
                # Check for escaped quote
                if ($prev_char eq '\\') {
                    my $backslash_count = 0;
                    my $check_pos = $i - 1;
                    while ($check_pos >= 0 && substr($line, $check_pos, 1) eq '\\') {
                        $backslash_count++;
                        $check_pos--;
                    }
                    if ($backslash_count % 2 == 1) {
                        $current_statement .= $char;
                        $prev_char = $char;
                        next;
                    }
                }
                $in_double_quote = !$in_double_quote;
                $current_statement .= $char;
                $prev_char = $char;
                next;
            }

            # Check for statement terminator (current delimiter)
            # Also check if the entire line is just the delimiter (common pattern)
            if ($current_delimiter ne ';' && $line =~ /^\s*\Q$current_delimiter\E\s*$/) {
                # Entire line is just the delimiter - end current statement
                my $stmt = $current_statement;
                $stmt =~ s/^\s+|\s+$//g;
                if ($stmt ne '') {
                    push @statements, $stmt;
                }
                $current_statement = '';
                $prev_char = '';
                next;  # Skip this line (it's just the delimiter)
            }

            my $delimiter_len = length($current_delimiter);
            if ($i + $delimiter_len <= $line_len) {
                my $possible_delimiter = substr($line, $i, $delimiter_len);
                if ($possible_delimiter eq $current_delimiter &&
                    !$in_single_quote && !$in_double_quote && !$in_dollar_quote) {
                    # Found delimiter - check if it's at end of line or followed by whitespace
                    my $after_delim = substr($line, $i + $delimiter_len);
                    if ($after_delim =~ /^\s*$/) {
                        # Don't include the delimiter in the statement - it will be added back in sqltrace formatting
                        my $stmt = $current_statement;
                        $stmt =~ s/^\s+|\s+$//g;
                        if ($stmt ne '') {
                            push @statements, $stmt;
                        }
                        $current_statement = '';
                        $prev_char = '';
                        $i += $delimiter_len - 1;  # Skip past delimiter
                        next;
                    }
                }
            }

            $current_statement .= $char;
            $prev_char = $char;
        }

        # Add newline if not at end of file
        if ($line_idx < @lines - 1) {
            $current_statement .= "\n";
        }
    }

    # Add remaining statement (but filter out DELIMITER commands)
    if ($current_statement =~ /\S/) {
        my $stmt = $current_statement;
        $stmt =~ s/^\s+|\s+$//g;
        # Don't add DELIMITER commands as statements
        if ($stmt ne '' && $stmt !~ /^\s*DELIMITER\s+/i) {
            push @statements, $stmt;
        }
    }

    # Final filter: remove any DELIMITER commands that might have slipped through
    @statements = grep { $_ !~ /^\s*DELIMITER\s+/i } @statements;

    return @statements;
}

sub initSeed {
    my $self = shift;

    return if not defined $self->config->seed();

    my $orig_seed = $self->config->seed();
    my $new_seed;

    if ($orig_seed eq 'time') {
        $new_seed = time();
    } elsif ($self->config->seed() eq 'epoch5') {
        $new_seed = time() % 100000;
    } elsif ($self->config->seed() eq 'random') {
        $new_seed = int(rand(32767));
    } else {
        $new_seed = $orig_seed;
    }

    if ($new_seed ne $orig_seed) {
        say("Converting --seed=$orig_seed to --seed=$new_seed");
        $self->config->property('seed', $new_seed);
    }
}

sub initGenerator {
    my $self = shift;

    my $generator_name = "GenTest::Generator::".$self->config->generator;
    say("Loading Generator $generator_name.") if rqg_debug();
    eval("use $generator_name");
    croak($@) if $@;

    if ($generator_name eq 'GenTest::Generator::FromGrammar') {
        if (not defined $self->config->grammar) {
            say("--grammar not specified but Generator is $generator_name");
            return STATUS_ENVIRONMENT_FAILURE;
        }

	$self->[GT_GRAMMAR] = GenTest::Grammar->new(
 	    grammar_file => $self->config->grammar,
            grammar_flags => (defined $self->config->property('skip-recursive-rules') ? GRAMMAR_FLAG_SKIP_RECURSIVE_RULES : undef )
        ) if defined $self->config->grammar;

	return STATUS_ENVIRONMENT_FAILURE if not defined $self->grammar();

	if ($self->config->redefine) {
	    foreach (@{$self->config->redefine}) {
	        $self->[GT_GRAMMAR] = $self->[GT_GRAMMAR]->patch(
                    GenTest::Grammar->new( grammar_file => $_ )
	        )
	    }
	}

	return STATUS_ENVIRONMENT_FAILURE if not defined $self->grammar();
    }

    $self->[GT_GENERATOR] = $generator_name->new(
        grammar => $self->grammar(),
        varchar_length => $self->config->property('varchar-length'),
        mask => $self->config->mask,
        mask_level => $self->config->property('mask-level')
    );

    return STATUS_ENVIRONMENT_FAILURE if not defined $self->generator();
}

sub isMySQLCompatible {
    my $self = shift;

    my $is_mysql_compatible = 1;

    foreach my $i (0..2) {
        next if $self->config->dsn->[$i] eq '';
        $is_mysql_compatible = 0 if ($self->config->dsn->[$i] !~ m{mysql|drizzle}sio);
    }

    return $is_mysql_compatible;
}

sub initReporters {
    my $self = shift;

    if (not defined $self->config->reporters or $#{$self->config->reporters} < 0) {
        $self->config->reporters([]);
        if ($self->isMySQLCompatible()) {
            $self->config->reporters(['ErrorLog', 'Backtrace']);
            push @{$self->config->reporters}, 'ValgrindXMLErrors' if (defined $self->config->property('valgrind-xml'));
            push @{$self->config->reporters}, 'ReplicationConsistency' if $self->config->rpl_mode ne '';
        }
    } else {
        ## Remove the "None" reporter
        foreach my $i (0..$#{$self->config->reporters}) {
            delete $self->config->reporters->[$i]
                if $self->config->reporters->[$i] eq "None"
                or $self->config->reporters->[$i] eq '';
        }
    }

    say("Reporters: ".($#{$self->config->reporters} > -1 ? join(', ', @{$self->config->reporters}) : "(none)"));

    my $reporter_manager = GenTest::ReporterManager->new();

    # pass option debug server to the reporter, for detecting the binary type.
    foreach my $i (0..2) {
        next if $self->config->dsn->[$i] eq '';
        foreach my $reporter (@{$self->config->reporters}) {
            my $add_result = $reporter_manager->addReporter($reporter, {
                dsn => $self->config->dsn->[$i],
                test_start => $self->[GT_TEST_START],
                test_end => $self->[GT_TEST_END],
                test_duration => $self->config->duration,
                debug_server => $self->config->debug_server->[$i],
                properties => $self->config
            });

            return $add_result if $add_result > STATUS_OK;
        }
    }

    $self->[GT_REPORTER_MANAGER] = $reporter_manager;
    return STATUS_OK;
}

sub initValidators {
    my $self = shift;

    if (not defined $self->config->validators or $#{$self->config->validators} < 0) {
        $self->config->validators([]);
        push(@{$self->config->validators}, 'ErrorMessageCorruption')
            if $self->isMySQLCompatible();

        # In case of multi-master topology (e.g. Galera with multiple "masters"),
        # we don't want to compare results after each query.

        unless ($self->config->property('multi-master')) {
            if ($self->config->dsn->[2] ne '') {
                push @{$self->config->validators}, 'ResultsetComparator3';
            } elsif ($self->config->dsn->[1] ne '') {
                push @{$self->config->validators}, 'ResultsetComparator';
            }
        }
        push @{$self->config->validators}, 'ReplicationSlaveStatus'
            if $self->config->rpl_mode ne '' && $self->isMySQLCompatible();
        push @{$self->config->validators}, 'MarkErrorLog'
            if (defined $self->config->valgrind) && $self->isMySQLCompatible();

        push @{$self->config->validators}, 'QueryProperties'
            if defined $self->grammar() && $self->grammar()->hasProperties() && $self->isMySQLCompatible();
    } else {
        ## Remove the "None" validator
        foreach my $i (0..$#{$self->config->validators}) {
            delete $self->config->validators->[$i]
                if $self->config->validators->[$i] eq "None"
                or $self->config->validators->[$i] eq '';
        }
    }

    ## Add the transformer validator if --transformers is specified
    ## and transformer validator not allready specified.

    if (defined $self->config->transformers and
        $#{$self->config->transformers} >= 0)
    {
        my $hasTransformer = 0;
        foreach my $t (@{$self->config->validators}) {
            if ($t eq 'Transformer' or $t eq 'TransformerLight') {
                $hasTransformer = 1;
                last;
            }
        }
        push @{$self->config->validators}, 'Transformer' if !$hasTransformer;
    }

    say("Validators: ".(defined $self->config->validators and $#{$self->config->validators} > -1 ? join(', ', @{$self->config->validators}) : "(none)"));

    say("Transformers: ".join(', ', @{$self->config->transformers}))
        if defined $self->config->transformers and $#{$self->config->transformers} > -1;

    return STATUS_OK;
}

sub copyLogFiles {
    my ($self, $logdir, $dsns) = @_;
    ## Do this only when tt-logging is enabled
    if (-e $self->config->property('report-tt-logdir')) {
        mkpath($logdir) if ! -e $logdir;

        # copy database logs
        foreach my $filename ($self->logFilesToReport()) {
            copyFileToDir($filename, $logdir);
        }
        # copy RQG log
        copyFileToDir($self->config->logfile, $logdir);
    }
}

sub copyFileToDir {
    my ($from, $todir) = @_;
    say("Copying '$from' to '$todir'");
    copy($from, $todir);
}


sub initXMLReport {
    my $self = shift;

    my $buildinfo;
    if (defined $self->config->property('xml-output')) {
        $buildinfo = GenTest::XML::BuildInfo->new(
            dsns => $self->config->dsn
        );
    }

    # XML:
    #  Define test suite name for reporting purposes.
    #  Until we support test suites and/or reports with multiple suites/tests,
    #  we use the test name as test suite name, from config option "testname".
    #  Default test name is the basename portion of the grammar file name.
    #  If a grammar file is not given, the default is "rqg_no_name".
    my $test_suite_name = $self->config->testname;
    if (not defined $test_suite_name) {
        if (defined $self->config->grammar) {
            $test_suite_name = basename($self->config->grammar, '.yy');
        } else {
            $test_suite_name = "rqg_no_name";
        }
    }

    $self->[GT_XML_TEST] = GenTest::XML::Test->new(
        id => time(),
        name => $test_suite_name,  # NOTE: Consider changing to test (or test case) name when suites are supported.
        logdir => $self->config->property('report-tt-logdir').'/'.$test_suite_name.isoUTCSimpleTimestamp,
        attributes => {
            engine => $self->config->engine,
            gendata => $self->config->gendata,
            grammar => $self->config->grammar,
            threads => $self->config->threads,
            queries => $self->config->queries,
            validators => join (',', @{$self->config->validators}),
            reporters => join (',', @{$self->config->reporters}),
            seed => $self->config->seed,
            mask => $self->config->mask,
            mask_level => $self->config->property('mask-level'),
            rows => $self->config->rows,
            'varchar-length' => $self->config->property('varchar-length')
        }
    );

    $self->[GT_XML_REPORT] = GenTest::XML::Report->new(
        buildinfo => $buildinfo,
        name => $test_suite_name,  # NOTE: name here refers to the name of the test suite or "test".
        tests => [  $self->XMLTest() ]
    );
}

sub reportXMLIncidents {
    my ($self, $total_status, $incidents) = @_;

    foreach my $incident (@$incidents) {
        $self->XMLTest()->addIncident($incident);
    }

    # If no Reporters reported an incident, and we have a test failure,
    # create an incident report and add it to the test report.
    if ((scalar(@$incidents) < 1) && ($total_status != STATUS_OK)) {
        my $unreported_incident = GenTest::Incident->new(
            result      => 'fail',   # can we have other results as incidents?
            description => 'Non-zero status code from RQG test run',
            signature   => 'Exit status '.$total_status # better than nothing?
        );
        # Add the incident to the test report
        $self->XMLTest()->addIncident($unreported_incident);
    }

    $self->XMLTest()->end($total_status == STATUS_OK ? "pass" : "fail");

    if (defined $self->config->property('xml-output')) {
        open (XML , '>'.$self->config->property('xml-output')) or carp("Unable to open ".$self->config->property('xml-output').": $!");
        print XML $self->XMLReport()->xml();
        close XML;
        say("XML report written to ". $self->config->property('xml-output'));
    }

    # XML Result reporting to Test Tool (TT).
    # Currently both --xml-output=<filename> and --report-xml-tt must be
    # set to trigger this.
    if (defined $self->config->property('report-xml-tt')) {
        my $xml_transporter = GenTest::XML::Transporter->new(
            type => $self->config->property('report-xml-tt-type')
        );

        # If xml-output option is not set, bail out. TODO: Make xml-output optional.
        if (not defined $self->config->property('xml-output')) {
            carp("ERROR: --xml-output=<filename> must be set when using --report-xml-tt");
        }

        my $xml_send_result = $xml_transporter->sendXML(
            $self->config->property('xml-output'),
            $self->config->property('report-xml-tt-dest')
        );

        if ($xml_send_result != STATUS_OK) {
            croak("Error from XML Transporter: $xml_send_result");
        }

        if (defined $self->config->logfile && defined
            $self->config->property('report-tt-logdir')) {
            $self->copyLogFiles($self->XMLTest->logdir(), $self->config->dsn);
        }
    }
}

1;

