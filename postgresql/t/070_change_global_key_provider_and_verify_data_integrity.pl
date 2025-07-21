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

# ====== STEP 1: Initialize Primary Node ======
diag("Initializing primary node and configuring TDE settings");
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init;

enable_pg_tde_in_conf($node_primary);
set_default_table_am_tde_heap($node_primary);

$node_primary->append_conf('postgresql.conf', "listen_addresses = '*'");
$node_primary->start;

# Common variables
my $dbname = 'test_db';
my $KMIP_PRO = 'kmip_keyring5';
my $VAULT_PRO = 'vault_keyring5';
my $FILE_PRO = 'file_keyring5';
my $KMIP_KEY = 'kmip_key5';
my $VAULT_KEY = 'vault_key5';
my $FILE_KEY = 'file_key5';

unlink('/tmp/file_keyring.per');
# ====== STEP 2: Ensure Database Exists and Enable pg_tde ======
diag("Ensuring database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set FILE Key Provider ======
diag("Adding FILE global key provider and setting encryption key");
add_global_key_provider($node_primary, $dbname, $FILE_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
));
set_global_key($node_primary, $dbname, $FILE_KEY, $FILE_PRO);

# ====== STEP 4: Create and Populate Table t1 ======
diag("Creating and populating table t1 using FILE key provider");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT, b VARCHAR) USING tde_heap;
INSERT INTO t1 VALUES (100, 'Bob'), (300, 'global');
SQL
verify_table_data($node_primary, $dbname, 't1', "100|Bob\n300|global");

# ====== STEP 5: Add and Set KMIP Key Provider ======
diag("Adding KMIP global key provider and setting encryption key");
add_global_key_provider($node_primary, $dbname, $KMIP_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
));
set_global_key($node_primary, $dbname, $KMIP_KEY, $KMIP_PRO);

# ====== STEP 6: Create and Populate Table t2 ======
diag("Creating and populating table t2 using KMIP key provider");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t2(a INT, b VARCHAR) USING tde_heap;
INSERT INTO t2 VALUES (100, 'Bob'), (200, 'global');
SQL
verify_table_data($node_primary, $dbname, 't2', "100|Bob\n200|global");

# ====== STEP 7: Add and Set Vault Key Provider ======
diag("Adding Vault global key provider and setting encryption key");
add_global_key_provider($node_primary, $dbname, $VAULT_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));
set_global_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# ====== STEP 8: Create and Populate Table t3 ======
diag("Creating and populating table t3 using Vault key provider");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t3(a INT, b VARCHAR) USING tde_heap;
INSERT INTO t3 VALUES (300, 'Percona'), (400, 'global');
SQL
verify_table_data($node_primary, $dbname, 't3', "300|Percona\n400|global");

# ====== STEP 9: Verify Key Info ======
diag("Verifying key information for the Vault key provider");
verify_key_info($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# ====== STEP 10: Verify Key Presence ======
diag("Verifying key presence using pg_tde_verify_key()");
my $verify_result = $node_primary->safe_psql($dbname, "SELECT pg_tde_verify_key();");
is($verify_result, '', "pg_tde_verify_key returns empty string when key is present");

# ====== STEP 11: Verify Row Counts Before Restart ======
diag("Verifying row counts in all tables before server restart");
verify_row_counts($node_primary, $dbname, [qw/t1 t2 t3/], '2');

# ====== STEP 12: Restart the Server ======
diag("Restarting the server...");
$node_primary->restart;

# ====== STEP 13: Verify Row Counts After Restart ======
diag("Verifying row counts in all tables after server restart");
verify_row_counts($node_primary, $dbname, [qw/t1 t2 t3/], '2');

done_testing();

# ===== Subroutines =====

# Subroutine to add a global key provider
sub add_global_key_provider {
    my ($node, $db, $provider_name, $setup_sql) = @_;
    my $result = invoke_add_key_provider_function($node, $db, $provider_name, $setup_sql);
    ok($result, "$provider_name global key provider created successfully");
}

# Subroutine to set a global key
sub set_global_key {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $result1 = invoke_add_key_function($node, $db, 'pg_tde_create_key_using_global_key_provider', $key_name, $provider_name);
    my $result = invoke_add_key_function($node, $db, 'pg_tde_set_key_using_global_key_provider', $key_name, $provider_name);
    ok($result, "$key_name global key was set successfully using provider $provider_name");
}

# Subroutine to verify table data
sub verify_table_data {
    my ($node, $db, $table, $expected_data) = @_;
    my $result = $node->safe_psql($db, "SELECT a, b FROM $table ORDER BY a;");
    chomp($result);
    is($result, $expected_data, "Table $table contents are as expected: $result");
}

# Subroutine to verify key info
sub verify_key_info {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $key_info = $node->safe_psql($db, "SELECT key_name, key_provider_name FROM pg_tde_key_info();");
    like($key_info, qr/^$key_name\|$provider_name$/m, "Key info matches expected values");
}

# Subroutine to verify row counts
sub verify_row_counts {
    my ($node, $db, $tables, $expected_count) = @_;
    foreach my $table (@$tables) {
        my $result = $node->safe_psql($db, "SELECT COUNT(*) FROM $table;");
        chomp($result);
        is($result, $expected_count, "Row count in $table is $expected_count");
    }
}