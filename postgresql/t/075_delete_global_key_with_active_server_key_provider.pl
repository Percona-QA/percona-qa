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
my $VAULT_PRO = 'vault_keyring11';
my $VAULT_KEY = 'vault_key11';
my $VAULT_SERVER_KEY = 'vault_server11';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';
my $GLOBAL_PROVIDER = 'global';
my $LOCAL_PROVIDER = 'local';

# ====== STEP 2: Ensure postgres Database Exists and Enable pg_tde ======
diag("Ensuring $DB_NAME database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $DB_NAME);
$node_primary->safe_psql($DB_NAME, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set SERVER Key Provider ======
diag("Adding Vault global key provider and setting server encryption key");
add_key_provider($node_primary, $DB_NAME, $VAULT_PRO, $GLOBAL_PROVIDER, sprintf(
    "SELECT pg_tde_add_global_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));
set_key($node_primary, $DB_NAME, $VAULT_SERVER_KEY, $VAULT_PRO, 
    'SERVER_KEY', 'pg_tde_create_key_using_global_key_provider');
set_key($node_primary, $DB_NAME, $VAULT_SERVER_KEY, $VAULT_PRO, 
    'SERVER_KEY', 'pg_tde_set_server_key_using_global_key_provider');
verify_server_key_info($node_primary, $DB_NAME, $VAULT_SERVER_KEY, $VAULT_PRO);

# ====== STEP 4: Delete Server Key Provider ======
diag("Delete the Global Key provider. Key is active. Must Fail");
my $delete_pr = invoke_delete_key_provider_function($node_primary, $DB_NAME, $VAULT_PRO, 'pg_tde_delete_global_key_provider');
ok(!$delete_pr, "Key provider $VAULT_PRO deletion fails as expected");

# ====== STEP 5: Enable WAL encryption ======
diag("Enabling WAL encryption");
$node_primary->safe_psql($DB_NAME, "ALTER SYSTEM SET pg_tde.wal_encrypt=ON;");
$node_primary->restart;

# ====== STEP 6: Delete Server Key Provider again ======
diag("Delete the Global Key provider again. Key is active. Must Fail");
$delete_pr = invoke_delete_key_provider_function($node_primary, $DB_NAME, $VAULT_PRO, 'pg_tde_delete_global_key_provider');
ok(!$delete_pr, "Key provider $VAULT_PRO deletion fails as expected");
verify_server_key_info($node_primary, $DB_NAME, $VAULT_SERVER_KEY, $VAULT_PRO);

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

# Subroutine to verify key info
sub verify_server_key_info {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $key_info = $node->safe_psql($db, "SELECT key_name, key_provider_name FROM pg_tde_server_key_info();");
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