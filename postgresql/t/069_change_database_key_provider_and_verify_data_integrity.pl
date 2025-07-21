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

# ====== STEP 2: Ensure Database Exists and Enable pg_tde ======
diag("Ensuring database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $DB_NAME);
$node_primary->safe_psql($DB_NAME, "CREATE EXTENSION pg_tde;");

# Common variables
my $dbname = 'test_db';
my $KMIP_PRO = 'kmip_keyring6';
my $VAULT_PRO = 'vault_keyring6';
my $FILE_PRO = 'file_keyring6';
my $KMIP_KEY = 'kmip_key6';
my $VAULT_KEY = 'vault_key6';
my $FILE_KEY = 'file_key6';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';

unlink('/tmp/keyring.file');
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set local FILE Key Provider ======
diag("Adding FILE database key provider and setting encryption key");
my $setup_sql_file = sprintf(
    "SELECT pg_tde_add_database_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
);
my $vault_result = invoke_add_key_provider_function($node_primary, $dbname, $FILE_PRO, $setup_sql_file);
ok($vault_result, "$FILE_PRO database key provider created successfully");
set_key($node_primary, $dbname, $FILE_KEY, $FILE_PRO, 'database_key', 'pg_tde_create_key_using_database_key_provider');
set_key($node_primary, $dbname, $FILE_KEY, $FILE_PRO, 'database_key', 'pg_tde_set_key_using_database_key_provider');

# ====== STEP 4: Add and Set local KMIP Key Provider ======
diag("Adding KMIP database key provider and setting encryption key");
my $setup_sql_kmip = sprintf(
    "SELECT pg_tde_add_database_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $KMIP_PRO, $setup_sql_kmip);
ok($vault_result, "$KMIP_PRO database key provider created successfully");

# ====== STEP 5: Add and Set local Vault_v2 Key Provider ======
diag("Adding KMIP database key provider and setting encryption key");
my $setup_sql_vault = sprintf(
    "SELECT pg_tde_add_database_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
);

$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $VAULT_PRO, $setup_sql_vault);
ok($vault_result, "$VAULT_PRO database key provider created successfully");

# ====== STEP 6: Create and Populate Table t1 ======
diag("Creating and populating table t1 using FILE key provider");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT, b varchar) USING tde_heap;
INSERT INTO t1 VALUES (200, 'Bob'), (300, 'khan');
SQL
verify_table_data($node_primary, $dbname, 't1', "200|Bob\n300|khan", $TDE_HEAP);
verify_key_info($node_primary, $dbname, $FILE_KEY, $FILE_PRO);

# ====== STEP 7: Change to KMIP Key Provider ======
diag("Changing database key provider to KMIP and setting encryption key");
$setup_sql_kmip = sprintf(
    "SELECT pg_tde_change_database_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $KMIP_PRO, $setup_sql_kmip);
ok($vault_result, "$KMIP_PRO database key provider changed successfully");
set_key($node_primary, $dbname, $KMIP_KEY, $KMIP_PRO, 'database_key', 'pg_tde_create_key_using_database_key_provider');
set_key($node_primary, $dbname, $KMIP_KEY, $KMIP_PRO, 'database_key', 'pg_tde_set_key_using_database_key_provider');
verify_key_info($node_primary, $dbname, $KMIP_KEY, $KMIP_PRO);

# ====== STEP 8: Create and Populate Table t1 ======
diag("Creating and populating table t1 using KMIP key provider");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t2(a INT, b varchar) USING tde_heap;
INSERT INTO t2 VALUES (200, 'Bob'), (300, 'Yan');
SQL
verify_table_data($node_primary, $dbname, 't2', "200|Bob\n300|Yan", $TDE_HEAP);

# ====== STEP 9: Change to VAULT_V2 Key Provider ======
diag("Changing database key provider to Vault_v2 and setting encryption key");
$setup_sql_vault = sprintf(
    "SELECT pg_tde_change_database_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $VAULT_PRO, $setup_sql_vault);
ok($vault_result, "$VAULT_PRO database key provider changed successfully");
set_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO, 'database_key', 'pg_tde_create_key_using_database_key_provider');
set_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO, 'database_key', 'pg_tde_set_key_using_database_key_provider');
verify_key_info($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# ====== STEP 10: Create and Populate Table t1 ======
diag("Creating and populating table t1 using Vault_v2 key provider");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t3(a INT, b varchar) USING tde_heap;
INSERT INTO t3 VALUES (200, 'Bob'), (300, 'Percona');
SQL
verify_table_data($node_primary, $dbname, 't3', "200|Bob\n300|Percona", $TDE_HEAP);

# ====== STEP 11: Verify Key Presence ======
my $verify_result = $node_primary->safe_psql($dbname,
            "SELECT pg_tde_verify_key();");
        is($verify_result, '',
            "pg_tde_verify_key returns empty string when key is present");

# "List of Database Key Providers"
my $local_providers = $node_primary->safe_psql(
    $dbname,
    "SELECT provider_name, provider_type FROM pg_tde_list_all_database_key_providers();"
);
diag("List of Database Key Providers: $local_providers");

# ====== STEP 12: Verify Row Counts Before Restart ======
diag("Verifying row counts in all tables before server restart");
foreach my $table (qw/t1 t2 t3/) {
    my $result = $node_primary->safe_psql($dbname, "SELECT COUNT(*) FROM $table");
    chomp($result);
    is($result, '2', "Row count in $table is unchanged before restart. $result");
}

# ====== STEP 13: Restart the Server ======
diag("Restarting the server...");
$node_primary->restart;

# ====== STEP 14: Verify Row Counts After Restart ======
diag("Verifying row counts in all tables after server restart");
foreach my $table (qw/t1 t2 t3/) {
    my $result = $node_primary->safe_psql($dbname, "SELECT COUNT(*) FROM $table");
    chomp($result);
    is($result, '2', "Row count in $table is unchanged after restart. $result");
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

# Subroutine to verify table data
sub verify_table_data {
    my ($node, $db, $table, $expected_data, $expected_am) = @_;
    my $result = $node->safe_psql($db, "SELECT * FROM $table;");
    my $result_am = $node->safe_psql($db, "SELECT pg_tde_is_encrypted('$table');");
    chomp($result);
    chomp($result_am);
    is($result, $expected_data, "Table $table contents are as expected: $result");
    is($result_am, $expected_am, "Table $table is using the expected access method: $result_am");
}

# Subroutine to verify key info
sub verify_key_info {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $key_info = $node->safe_psql($db, "SELECT key_name, key_provider_name FROM pg_tde_key_info();");
    like($key_info, qr/^$key_name\|$provider_name$/, "Key info is correct");
}

sub invoke_delete_key_provider_function {
    my ($node, $dbname, $provider_name, $function_name) = @_;
    eval {
        $node->safe_psql($dbname, "SELECT $function_name('$provider_name')");
        1;
    } or do {
        diag("$provider_name key provider deletion failed: $@");
        return 0;
    };
    return 1;
}