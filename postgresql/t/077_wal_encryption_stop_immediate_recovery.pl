use strict;
use warnings FATAL => 'all';
use File::Basename;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use lib 't';
use pgtde;
use tde_helper;

PGTDE::setup_files_dir(basename($0));

# ====== STEP 1: Initialization ======
diag("Initializing primary node and configuring TDE settings");
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init;

enable_pg_tde_in_conf($node_primary);
set_default_table_am_tde_heap($node_primary);

$node_primary->append_conf('postgresql.conf', q{
    listen_addresses = '*'
    logging_collector = on
    log_directory = 'log'
    log_filename = 'server.log'
    log_statement = 'all'
});
$node_primary->start;
# by default PostgreSQL::Test::Cluster doesn't restart after a crash
$node_primary->safe_psql(
	'postgres',
	q[ALTER SYSTEM SET restart_after_crash = 1;
				   ALTER SYSTEM SET log_connections = 1;
				   SELECT pg_reload_conf();]);

# Common variables
my $dbname = 'wal_db';
my $FILE_PRO = 'file_provider';
my $FILE_KEY = 'file_key';
my $FILE_PRO_GLOBAL = 'file_provider_global';
my $SERVER_KEY = 'server_key';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';

# Define test values for WAL-related options
my %test_values = (
    wal_compression => "on",
    wal_log_hints => "on",
    wal_writer_delay => "1000",
    wal_writer_flush_after => "256",
    wal_level => "logical",
    wal_buffers => "1024",
    max_wal_size => "2048",
    min_wal_size => "128",
    wal_init_zero => "off",
    wal_sync_method => "fsync",
    wal_retrieve_retry_interval => "5000",
    #wal_segment_size => "16777", # Not applicable in PostgreSQL 15+
    wal_sender_timeout => "60000",
    wal_recycle => "off",
    wal_receiver_create_temp_slot => "on",
    wal_keep_size => 5,
    track_wal_io_timing => "on",
    summarize_wal => "on",
);

# ====== STEP 2: Ensure postgres Database Exists and Enable pg_tde ======
diag("Ensuring $DB_NAME database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set default Key Provider ======
diag("Adding File global key provider and setting server encryption key");
add_key_provider($node_primary, $dbname, 'global', $FILE_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_file('%s', '/tmp/global_keyring.file');",
    $FILE_PRO_GLOBAL
));
set_key($node_primary, $dbname, $SERVER_KEY, $FILE_PRO_GLOBAL, 'server_key', 'pg_tde_create_key_using_global_key_provider');
set_key($node_primary, $dbname, $SERVER_KEY, $FILE_PRO_GLOBAL, 'server_key', 'pg_tde_set_server_key_using_global_key_provider');

diag("Adding File local key provider and setting default encryption key");
add_key_provider($node_primary, $dbname, 'local', $FILE_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_file('%s', '/tmp/local_keyring.file');",
    $FILE_PRO
));
set_key($node_primary, $dbname, $FILE_KEY, $FILE_PRO, 'local_key', 'pg_tde_create_key_using_database_key_provider');
set_key($node_primary, $dbname, $FILE_KEY, $FILE_PRO, 'local_key', 'pg_tde_set_key_using_database_key_provider');

# ====== STEP 4: Enable WAL encryption ======
diag("Enabling WAL encryption");
$node_primary->append_conf('postgresql.conf', "pg_tde.wal_encrypt = 'on'");
$node_primary->restart;

# ====== STEP 5: Test WAL Options ======
diag("Testing WAL-related options");
foreach my $wal_option (keys %test_values) {
    my $test_value = $test_values{$wal_option};
    diag("Testing WAL option: $wal_option with value: $test_value");

    # Ensure wal_level is compatible for summarize_wal
    if ($wal_option eq 'summarize_wal') {
        diag("Setting wal_level to 'logical' for summarize_wal");
        $node_primary->safe_psql($dbname, "ALTER SYSTEM SET wal_level = 'logical';");
        $node_primary->restart;
    }
    
    # Apply the WAL option
    $node_primary->safe_psql($dbname, "ALTER SYSTEM SET $wal_option = '$test_value';");
    $node_primary->restart;

    # Simulate workload
    diag("Simulating workload for $wal_option=$test_value");
    $node_primary->safe_psql($dbname, "CREATE TABLE IF NOT EXISTS test_wal_crash(id SERIAL PRIMARY KEY, txt TEXT);");
    $node_primary->safe_psql($dbname, "INSERT INTO test_wal_crash(txt) SELECT md5(random()::text) FROM generate_series(1,1000);");

    # Stop the server immediately to simulate a crash 
    diag("Stopping the primary node with immediate mode");
    $node_primary->stop('immediate');

    # Wait for the server to stop completely
    diag("Waiting for the server to stop completely...");
    my $max_retries = 10;
    my $retry_count = 0;
    while ($retry_count < $max_retries) {
        # Check if the postmaster.pid file exists
        my $pid_file = $node_primary->data_dir . '/postmaster.pid';
        if (!-e $pid_file) {
            diag("Server has stopped.");
            last;
        }
        diag("Server is still running. Retrying in 1 second...");
        sleep 1;
        $retry_count++;
    }

    if ($retry_count == $max_retries) {
        die "Server did not stop after $max_retries seconds.";
    }

    # Start the server again
    diag("Starting the primary node after crash...");
    $node_primary->start;

    # Verify recovery
    diag("Verifying recovery for $wal_option=$test_value");
    my $recovery_result = $node_primary->safe_psql($dbname, "SELECT count(*) FROM test_wal_crash;");
    ok($recovery_result > 0, "Recovery successful for $wal_option=$test_value");

    #$monitor->finish;
}

done_testing();

# ====== SUBROUTINES ======
# Subroutine to add a key provider
sub add_key_provider {
    my ($node, $db, $provider_name, $provider_type, $setup_sql) = @_;
    my $result = invoke_add_key_provider_function($node, $db, $provider_name, $setup_sql);
    ok($result, "$provider_name $provider_type key provider created successfully");
}

# Subroutine to set a key
sub set_key {
    my ($node, $db, $key_name, $provider_name, $key_type, $function_name) = @_;
    my $result = invoke_add_key_function($node, $db, $function_name, $key_name, $provider_name);
    ok($result, "$key_name $key_type key was set successfully using provider $provider_name");
}
