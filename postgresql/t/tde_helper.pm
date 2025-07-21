package tde_helper;
# This file contains helper functions for pg_tde tests
# It includes functions for running sysbench, performing node operations,
# and checking encryption status.
# For KMIP and VAULT server update the URL or define environment variable

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;

use File::Basename;
use File::Compare;
use Test::More;
use Time::HiRes qw(time sleep);
use IPC::Run qw(run);
use POSIX ":sys_wait_h";
use File::Temp qw(tempfile);
use POSIX qw(_exit);

use strict;
use warnings;
use Exporter qw(import);


# Export these variables to any script that uses helper.pm
our @EXPORT = qw(
    $DB_NAME
    $KMIP_URL
    $KMIP_PORT
    $KMIP_SERVER_CA
    $KMIP_SERVER_CLIENT_KEY
    $VAULT_URL
    $VAULT_PORT
    $VAULT_SERVER_URL
    $VAULT_TOKEN
    $VAULT_SECRET_MOUNT_POINT
    run_in_background
    wait_for_all_background_tasks
    run_sysbench_prepare
    run_sysbench_script
    run_oltp_insert
    run_oltp_bulk_insert
    run_oltp_read_write
    run_oltp_delete
    run_update_index
    perform_node_operations
    rotate_keys
    toggle_table_am
    check_encryption_status
    setup_pg_tde_global_environment
    setup_pg_tde_db_environment
    setup_encryption
    set_wal_encryption_and_restart
    set_default_table_am_tde_heap
    enable_pg_tde_in_conf
    ensure_database_exists_and_accessible
    invoke_add_key_function
    invoke_add_key_provider_function
);

our $DB_NAME = "postgres";
our $KMIP_PORT = 5696;
our $KMIP_SERVER_CA = "/tmp/certs/server_certificate.pem";
our $KMIP_SERVER_CLIENT_KEY = "/tmp/certs/client_key_jane_doe.pem";
our $VAULT_PORT = 8200;
our $VAULT_TOKEN = 'root';
our $VAULT_SECRET_MOUNT_POINT = 'secret';

# Environment override support
our $KMIP_URL = $ENV{KMIP_URL} // "kmip1";
our $VAULT_URL = $ENV{VAULT_URL} // "172.18.0.7";

# Constructed URL based on final VAULT_URL and port
our $VAULT_SERVER_URL = "http://$VAULT_URL:$VAULT_PORT";

our %TASK_PIDS;

# === Run parallel tasks ===
# This function runs a subroutine in the background and tracks its PID
sub run_in_background {
    my ($sub, $name, @args) = @_;

    my $pid = fork();
    if (!defined $pid) {
        die "Cannot fork: $!";
    } elsif ($pid == 0) {
        # Child process
        eval {
            diag("Starting background task: $name");
            $sub->(@args);
            diag("Completed background task: $name");
            POSIX::_exit(0);
        };
        if ($@) {
            diag("Error in $name: $@");
            POSIX::_exit(1);
        }
    } else {
        # Parent process
        $TASK_PIDS{$pid} = $name;
        diag("Started $name (PID: $pid)");
    }
}

sub wait_for_all_background_tasks {
    for my $pid (keys %TASK_PIDS) {
        my $name = $TASK_PIDS{$pid};
        my $waited = waitpid($pid, 0);
        my $status = $? >> 8;
        diag("Background task '$name' (PID $pid) exited with status $status");
    }
}

# ========== SYSBENCH FUNCTIONS ==========
# This function runs sysbench prepare to create the test tables
sub run_sysbench_prepare {
    diag("Waiting for all background tasks...");
    my ($node, $db_name, $tables, $threads) = @_; 
    my $user = `whoami`;
    chomp($user);
    my $port = $node->port;
	my $oltp_insert = '/usr/share/sysbench/oltp_insert.lua';

	my @prepare_cmd = (
		'sysbench', $oltp_insert,
		"--pgsql-user=$user",
		"--pgsql-db=$db_name",
		'--db-driver=pgsql',
		"--pgsql-port=$port",
		"--threads=$threads",
		"--tables=$tables",
		'--table-size=1000',
		'prepare'
	);

    diag("Preparing sysbench data...");
	run \@prepare_cmd or die "sysbench prepare failed on " . $node->name . ": $?";
}

sub run_sysbench_script {
    my ($node, $db_name, $script, $tables, $threads, $duration) = @_;

    my $user = `whoami`;
    chomp($user);
    my $port = $node->port;
    my $end_time = time() + $duration;

    while (time() < $end_time) {
        my @cmd = (
            'sysbench', $script,
            "--pgsql-user=$user",
            "--pgsql-db=$db_name",
            '--db-driver=pgsql',
            "--pgsql-port=$port",
            "--threads=$threads",
            "--tables=$tables",
            "--time=30",
            '--report-interval=1',
            'run'
        );

        diag("Running sysbench workload chunk: $script");
        system(@cmd);

        if ($? != 0) {
            diag("Sysbench $script chunk failed, retrying in 5s...");
            sleep(5);
            eval {
                $node->psql($db_name, 'SELECT 1');
            };
            if ($@) {
                diag("Server not responding during $script, waiting for recovery...");
                sleep(10);
            }
        }
    }
}

sub run_oltp_insert {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/oltp_insert.lua',
                        $tables, $threads, $duration);
}

sub run_oltp_bulk_insert {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/bulk_insert.lua',
                        $tables, $threads, $duration);
}

sub run_oltp_read_write {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/oltp_read_write.lua',
                        $tables, $threads, $duration);
}

sub run_oltp_delete {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/oltp_delete.lua',
                        $tables, $threads, $duration);
}

sub run_update_index {
    my ($node, $db_name, $tables, $threads, $duration) = @_;
    run_sysbench_script($node, $db_name, '/usr/share/sysbench/update_index.lua',
                        $tables, $threads, $duration);
}

# ========== TOGGLE OPERATIONS ==========
# This function randomly performs operations on the primary and replica nodes
# such as crashing, restarting, and promoting/demoting.
sub perform_node_operations {
    my ($primary, $replica, $end_time) = @_;
    
    while (time() < $end_time) {
        my $operation = int(rand(5));
        
        if ($operation == 0) {
            # Crash primary
            diag("Crashing primary node...");
            eval { $primary->stop('immediate') };
            sleep(5 + rand(10));
            diag("Restarting primary node...");
            eval { $primary->start() };
        }
        elsif ($operation == 1) {
            # Crash replica
            diag("Crashing replica node...");
            eval { $replica->stop('immediate') };
            sleep(5 + rand(10));
            diag("Restarting replica node...");
            eval { $replica->start() };
        }
        elsif ($operation == 2) {
            # Restart primary cleanly
            diag("Restarting primary node cleanly...");
            eval { $primary->restart() };
        }
        # elsif ($operation == 3) {
        #     # Promote replica
        #     diag("Promoting replica...");
        #     eval { $replica->promote() };
        #     sleep(5);
        #     # Demote back to replica
        #     diag("Demoting back to replica...");
        #     $replica->stop();
        #     $replica->set_standby_mode();
        #     $replica->start();
        # }
        else {
            # Just wait
            sleep(10);
        }
        
        # Random delay between operations
        sleep(5 + rand(15));
    }
}

# This function randomly rotates keys and toggles WAL encryption
sub rotate_keys {
    my ($node, $db_name, $end_time) = @_;
    
    while (time() < $end_time) {
        my $operation = int(rand(3));
        
        if ($operation == 0) {
            # Rotate WAL key
            my $rand = int(rand(1000000)) + 1;
            diag("Rotating WAL key...");
            eval {
                $node->safe_psql($db_name,
                    "SELECT pg_tde_create_key_using_global_key_provider('server_key_$rand', 'global_key_provider', 'true');"
                );
                $node->safe_psql($db_name,
                    "SELECT pg_tde_set_server_key_using_global_key_provider('server_key_$rand', 'global_key_provider', 'true');"
                );
            };
            if ($@) {
                die "Query failed: $@";
            }
        }
        elsif ($operation == 1) {
            # Rotate master key
            my $rand = int(rand(1000000)) + 1;
            diag("Rotating master key...");
            eval {
                $node->safe_psql($db_name,
                    "SELECT pg_tde_create_key_using_database_key_provider('db_key_$rand', 'local_key_provider', 'true');"
                );
                $node->safe_psql($db_name,
                    "SELECT pg_tde_set_key_using_database_key_provider('db_key_$rand', 'local_key_provider', 'true');"
                );
            };
            if ($@) {
                die "Query failed: $@";
            }
        }
        else {
            # Toggle WAL encryption
            my $value = (int(rand(2)) == 0) ? "on" : "off";
            diag("Setting WAL encryption to $value");
            eval {
                $node->safe_psql($db_name,
                    "ALTER SYSTEM SET pg_tde.wal_encrypt = '$value';"
                );
                $node->restart();
            };
            if ($@) {
                die "Query failed: $@";
            }
        }
        sleep(10 + rand(20));
    }
}

# This function randomly changes the access method of a table between heap and tde_heap
sub toggle_table_am {
    my ($node, $db_name, $tables, $end_time) = @_;
    
    while (time() < $end_time) {
        my $table = int(rand($tables)) + 1;
        my $heap = (int(rand(2)) == 0) ? "heap" : "tde_heap";
        
        diag("Changing table sbtest$table to use $heap");
        eval {
            $node->safe_psql($db_name,
                "ALTER TABLE sbtest$table SET ACCESS METHOD $heap;"
            );
        };
        if ($@) {
            die "Query failed: $@";
        }
        
        sleep(5 + rand(15));
    }
}

sub check_encryption_status
{
	my ($node, $db_name, $table_name, $expected) = @_;
	my $result =
	  $node->safe_psql($db_name, "SELECT pg_tde_is_encrypted('$table_name')");
	return $result;
}

# Set up pg_tde extension and add a global key provider and set the server key
sub setup_pg_tde_global_environment
{
	my ($node, $db_name, $key_name, $provider_name, $provider_path) = @_;
	$node->safe_psql($db_name, 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
	$node->safe_psql($db_name,
		"SELECT pg_tde_add_global_key_provider_file('$provider_name', '$provider_path');");
	$node->safe_psql($db_name, 'postgres',
		"SELECT pg_tde_create_key_using_global_key_provider('$key_name', '$provider_name');");
	$node->safe_psql($db_name, 'postgres',
		"SELECT pg_tde_set_server_key_using_global_key_provider('$key_name', '$provider_name');");
}

# Set up pg_tde extension and add a database key provider and set the database key
sub setup_pg_tde_db_environment
{
	my ($node, $db_name, $key_name, $provider_name, $provider_path) = @_;
	$node->safe_psql($db_name, 'postgres', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
	$node->safe_psql($db_name, 'postgres',
		"SELECT pg_tde_add_database_key_provider_file('$provider_name', '$provider_path');");
	$node->safe_psql($db_name, 'postgres',
		"SELECT pg_tde_create_key_using_database_key_provider('$key_name', '$provider_name');");
	$node->safe_psql($db_name, 'postgres',
		"SELECT pg_tde_set_key_using_database_key_provider('$key_name', '$provider_name');");
}

# Set up pg_tde in postgresql.conf
sub enable_pg_tde_in_conf
{
	my ($node) = @_;
	$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_tde'");
}

# Set default table access method to tde_heap
sub set_default_table_am_tde_heap
{
	my ($node) = @_;
	$node->append_conf('postgresql.conf', "default_table_access_method = 'tde_heap'");
}

# Set pg_tde.wal_encrypt and restart the server
sub set_wal_encryption_and_restart
{
	my ($node, $db_name, $value) = @_;

	die "Invalid value for wal_encrypt: must be 'on' or 'off'\n"
		unless $value eq 'on' || $value eq 'off';

	$node->safe_psql($db_name, "ALTER SYSTEM SET pg_tde.wal_encrypt = $value;");
	$node->restart;
}

sub ensure_database_exists_and_accessible {
    my ($node, $db_name) = @_;

    # Create database only if it's not 'postgres'
    if ($db_name ne 'postgres') {
        $node->safe_psql('postgres', "CREATE DATABASE $db_name");
    }

    # Run a test query to ensure it's usable
    $node->safe_psql($db_name, "SELECT 1");

    diag("Created database $db_name and ran a test query");
}

# Setup pg_tde encryption on the primary node
sub setup_encryption {
    my ($node, $db_name) = @_;
    $node->safe_psql($db_name, 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
    $node->safe_psql($db_name, 
        "SELECT pg_tde_add_global_key_provider_file('global_key_provider', '/tmp/global_keyring.file');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_create_key_using_global_key_provider('global_key', 'global_key_provider');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_set_server_key_using_global_key_provider('global_key', 'global_key_provider');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_add_database_key_provider_file('local_key_provider', '/tmp/db_keyring.fil');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_create_key_using_database_key_provider('local_key', 'local_key_provider');");
    $node->safe_psql($db_name,
        "SELECT pg_tde_set_key_using_database_key_provider('local_key', 'local_key_provider');");
}

# This function add a key using the specified function and provider
# It takes the database name, function name, key name, and provider name as arguments
# and returns 1 on success or 0 on failure
sub invoke_add_key_function {
    my ($node, $dbname, $function_name, $key_name, $provider_name) = @_;
    eval {
    $node->safe_psql($dbname,
            "SELECT $function_name('$key_name', '$provider_name');");
        1;
    } or do {
        fail("Failed to set key using $provider_name: $@");
        return 0;
    };
    return 1;
}

# This function adds a key provider using the specified SQL command
# It takes the database name, provider name, and SQL command as arguments
# and returns 1 on success or 0 on failure
sub invoke_add_key_provider_function {
    my ($node, $dbname, $provider_name, $setup_sql) = @_;
    eval {
        $node->safe_psql($dbname, $setup_sql);
        1;
    } or do {
        diag("$provider_name key provider creation failed: $@");
        return 0;
    };
    return 1;
}

1;

