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

$node_primary->append_conf('postgresql.conf', "listen_addresses = '*'");
$node_primary->start;

# Common variables
my $dbname = 'test_db';
my $KMIP_PRO = 'kmip_keyring9';
my $VAULT_PRO = 'vault_keyring9';
my $FILE_PRO = 'file_keyring9';
my $KMIP_KEY = 'kmip_key9';
my $VAULT_KEY = 'vault_key9';
my $VAULT_KEY1 = 'vault_key91';
my $VAULT_KEY2 = 'vault_key92';
my $FILE_KEY = 'file_key9';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';

# ====== STEP 2: Ensure Database Exists and Enable pg_tde ======
diag("Ensuring database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $DB_NAME);
$node_primary->safe_psql($DB_NAME, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set Vault Key Provider ======
diag("Adding Vault global key provider and setting default encryption key");
add_key_provider($node_primary, $DB_NAME, $VAULT_PRO, 'global', sprintf(
    "SELECT pg_tde_add_global_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));
set_key($node_primary, $DB_NAME, $VAULT_KEY, $VAULT_PRO, 'default_key_global', 'pg_tde_set_default_key_using_global_key_provider');

# ====== STEP 4: Create and Verify Table t1 ======
diag("Creating table t1 and verifying data and encryption");
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
INSERT INTO t1 VALUES (101, 'James Bond 007 from t1');
SQL
verify_table_data($node_primary, $dbname, 't1', "101|James Bond 007 from t1", $TDE_HEAP);
verify_key_info($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# ====== STEP 5: Rotate Vault Key ======
diag("Rotating Vault default global key");
set_key($node_primary, $DB_NAME, $VAULT_KEY1, $VAULT_PRO, 'default_key_global', 'pg_tde_set_default_key_using_global_key_provider');

# ====== STEP 6: Create and Verify Table t2 ======
diag("Creating table t2 and verifying data and encryption");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
INSERT INTO t2 VALUES (101, 'Ruskin Bond 007 from t2');
SQL
verify_table_data($node_primary, $dbname, 't2', "101|Ruskin Bond 007 from t2", $TDE_HEAP);
verify_table_data($node_primary, $dbname, 't1', "101|James Bond 007 from t1", $TDE_HEAP);
verify_key_info($node_primary, $dbname, $VAULT_KEY1, $VAULT_PRO);

# ====== STEP 7: Add and Set Database File Key Provider ======
diag("Adding and setting Database File key provider");
add_key_provider($node_primary, $dbname, 'local', $FILE_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
));
set_key($node_primary, $dbname, $FILE_KEY, $FILE_PRO, 'database_key', 'pg_tde_set_key_using_database_key_provider');

# ====== STEP 8: Create and Verify Table t3 ======
diag("Creating table t3 and verifying data and encryption");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t3(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
INSERT INTO t3 VALUES (101, 'James Bond from t3');
SQL
verify_table_data($node_primary, $dbname, 't3', "101|James Bond from t3", $TDE_HEAP);
verify_table_data($node_primary, $dbname, 't2', "101|Ruskin Bond 007 from t2", $TDE_HEAP);
verify_table_data($node_primary, $dbname, 't1', "101|James Bond 007 from t1", $TDE_HEAP);
verify_key_info($node_primary, $dbname, $FILE_KEY, $FILE_PRO);

# ====== STEP 9: Rotate Vault Key ======
diag("Rotating Vault key and performing key rotation 10 times");
set_key($node_primary, $dbname, $VAULT_KEY2, $VAULT_PRO, 'set_key_global', 'pg_tde_set_key_using_global_key_provider');
for my $i (1 .. 10) {
    $node_primary->safe_psql($dbname, "SELECT pg_tde_set_key_using_database_key_provider('$FILE_KEY', '$FILE_PRO');");
    $node_primary->safe_psql($dbname, "SELECT pg_tde_set_key_using_global_key_provider('$VAULT_KEY2', '$VAULT_PRO');");
}

# ====== STEP 10: Delete Local Key Provider ======
diag("Deleting local key provider and verifying data");
my $delete_pr = invoke_delete_key_provider_function($node_primary, $dbname, $FILE_PRO, 'pg_tde_delete_database_key_provider');
ok($delete_pr, "Key provider $FILE_PRO deleted successfully");

# ====== STEP 11: Restart Server and Final Verification ======
diag("Restarting server and verifying data after key rotation");
$node_primary->restart;
verify_table_data($node_primary, $dbname, 't3', "101|James Bond from t3", $TDE_HEAP);
verify_table_data($node_primary, $dbname, 't2', "101|Ruskin Bond 007 from t2", $TDE_HEAP);
verify_table_data($node_primary, $dbname, 't1', "101|James Bond 007 from t1", $TDE_HEAP);
verify_key_info($node_primary, $dbname, $VAULT_KEY2, $VAULT_PRO);

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
