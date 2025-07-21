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
my $KMIP_PRO = 'kmip_keyring10';
my $VAULT_PRO = 'vault_keyring10';
my $FILE_PRO = 'file_keyring10';
my $KMIP_KEY = 'kmip_key10';
my $VAULT_KEY = 'vault_key10';
my $FILE_KEY = 'file_key10';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';
my $GLOBAL_PROVIDER = 'global';
my $LOCAL_PROVIDER = 'local';

# ====== STEP 2: Ensure postgres Database Exists and Enable pg_tde ======
diag("Ensuring $DB_NAME database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $DB_NAME);
$node_primary->safe_psql($DB_NAME, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set Vault Key Provider ======
diag("Adding Vault global key provider and setting default encryption key");
add_key_provider($node_primary, $DB_NAME, $VAULT_PRO, $GLOBAL_PROVIDER, sprintf(
    "SELECT pg_tde_add_global_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));

# ====== STEP 4: Ensure Database Exists and Enable pg_tde ======
diag("Ensuring database $dbname exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# ====== STEP 5: Add local key to database ======
diag("Adding a local key using global key provider for database $dbname");
set_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO, 'local_key_global', 'pg_tde_create_key_using_global_key_provider');
set_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO, 'local_key_global', 'pg_tde_set_key_using_global_key_provider');

# ====== STEP 6: Create and Verify Table t1 ======
diag("Creating table t1 and verifying data and encryption");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t10(a int, b varchar) USING tde_heap;
INSERT INTO t10 VALUES(10, 'percona');
SQL
verify_table_data($node_primary, $dbname, 't10', "10|percona", $TDE_HEAP);
verify_key_info($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# ====== STEP 7: Delete Global Key Provider ======
diag("Delete the Global Key provider. Must Fail");
my $delete_pr = invoke_delete_key_provider_function($node_primary, $dbname, $VAULT_PRO, 'pg_tde_delete_global_key_provider');
ok(!$delete_pr, "Key provider $VAULT_PRO deletion fails as expected");

# ====== STEP 8: Restart Server ======
diag("Restarting server to verify that the database key provider is still active");
$node_primary->restart;

# ====== STEP 9: Verify Table Data ======
diag("Verifying table data after server restart");
verify_table_data($node_primary, $dbname, 't10', "10|percona", $TDE_HEAP);

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