#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use File::Basename;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use lib 't';
use pgtde;
use tde_helper;
use Time::HiRes qw(time sleep);
use IPC::Run qw(run);
use POSIX ":sys_wait_h";
use File::Temp qw(tempfile);
use POSIX qw(_exit);


PGTDE::setup_files_dir(basename($0));

# Configuration
my $TEST_DURATION = 60;  # 5 minutes total test duration
my $TABLES = 10;
my $THREADS = 4;
my $DB_NAME = 'postgres';
my $VERIFICATION_RETRIES = 3;
my $VERIFICATION_DELAY = 5;

# Initialize nodes

my ($primary, $replica) = setup_servers();

# Prepare test data
run_sysbench_prepare($primary, $DB_NAME, $TABLES, $THREADS);
run_oltp_bulk_insert($primary, $DB_NAME, $TABLES, $THREADS);

# Start background processes
my %TASK_PIDS;
my $start_time = time();
my $end_time = $start_time + $TEST_DURATION;

run_in_background(\&run_oltp_read_write, "OLTP Read Write", $primary, $DB_NAME, $TABLES, $THREADS, $TEST_DURATION);
run_in_background(\&run_oltp_delete,     "OLTP Delete",     $primary, $DB_NAME, $TABLES, $THREADS, $TEST_DURATION);
run_in_background(\&run_update_index,    "Update Index",    $primary, $DB_NAME, $TABLES, $THREADS, $TEST_DURATION);
run_in_background(\&perform_node_operations, "node operations", $primary, $replica, $end_time);
run_in_background(\&rotate_keys, "key rotation", $primary, $DB_NAME, $end_time);
run_in_background(\&toggle_table_am, "feature toggle", $primary, $DB_NAME, $TABLES, $end_time);

# Wait for all background processes
diag("Test running for $TEST_DURATION seconds...");
diag("Waiting for all background tasks...");
wait_for_all_background_tasks();
diag("All background tasks completed.");

verfiy_data_on_nodes($primary, $replica, $TABLES);

done_testing();


# ==========  SUBROUTINES ==========

# ========== SERVER MANAGEMENT ==========
sub setup_servers {
    my $primary = PostgreSQL::Test::Cluster->new('primary');
    $primary->init(
        allows_streaming => 1,
	    auth_extra => [ '--create-role', 'repl_role' ]);
    
    $primary->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_tde'");
    $primary->append_conf('postgresql.conf', "default_table_access_method = 'tde_heap'");
    $primary->append_conf('postgresql.conf', "max_connections = 200");
    $primary->append_conf('postgresql.conf', "listen_addresses = '*'");
    $primary->append_conf('pg_hba.conf', "host replication repuser 127.0.0.1/32 trust");

    $primary->start;
    setup_encryption($primary, $DB_NAME);

    # Setup replica
    $primary->backup('backup');
    my $replica = PostgreSQL::Test::Cluster->new('replica');
    $replica->init_from_backup($primary, 'backup', has_streaming => 1);
    $replica->set_standby_mode();
    $replica->start;

    return ($primary, $replica);
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

#============= TEST OPERATIONS ==========
sub verfiy_data_on_nodes {
    my ($primary, $replica, $tables) = @_;
    PGTDE::append_to_result_file("-- At primary");
    PGTDE::psql($primary, 'postgres',
    "CREATE TABLE test_enc (x int PRIMARY KEY) USING tde_heap;");
    PGTDE::psql($primary, 'postgres',
        "INSERT INTO test_enc (x) VALUES (1), (2);");

    PGTDE::psql($primary, 'postgres',
        "CREATE TABLE test_plain (x int PRIMARY KEY) USING heap;");
    PGTDE::psql($primary, 'postgres',
        "INSERT INTO test_plain (x) VALUES (3), (4);");

    PGTDE::psql($primary, 'postgres',
        "select * from test_enc;");
    PGTDE::psql($primary, 'postgres',
        "select * from test_plain;");

    $primary->wait_for_catchup('replica');

    PGTDE::append_to_result_file("-- At replica");
    PGTDE::psql($replica, 'postgres',
        "select * from test_enc;");
    PGTDE::psql($replica, 'postgres',
        "select * from test_plain;");

    for my $i (1..$tables) {
        my ($primary_count, $replica_count);
        $primary_count = $primary->safe_psql($DB_NAME, "SELECT COUNT(*) FROM sbtest$i;");
        $replica_count = $replica->safe_psql($DB_NAME, "SELECT COUNT(*) FROM sbtest$i;");
        is($primary_count, $replica_count, "Table sbtest$i consistency check.Primary: $primary_count, Replica: $replica_count");
    }
    # Compare the expected and out file
    my $compare = PGTDE->compare_results();

    is($compare, 0,
        "Compare Files: $PGTDE::expected_filename_with_path and $PGTDE::out_filename_with_path files."
    );
    return 0;
}



