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

# Initialize primary node
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init;

enable_pg_tde_in_conf($node_primary);
set_default_table_am_tde_heap($node_primary);

$node_primary->append_conf('postgresql.conf', "listen_addresses = '*'");
$node_primary->start;

# Common variables
my $dbname = 'test_db';
my $KMIP_PRO = 'kmip_keyring7';
my $VAULT_PRO = 'vault_keyring7';
my $FILE_PRO = 'file_keyring7';
my $KMIP_KEY = 'kmip_key7';
my $VAULT_KEY = 'vault_key7';
my $FILE_KEY = 'file_key7';

# Ensure database exists and create pg_tde extension
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# Add and set Vault key provider
add_global_key_provider($node_primary, $dbname, $VAULT_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));
set_global_default_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# Create and populate table
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
INSERT INTO t1 VALUES (101, 'James Bond');
SQL

# Verify table data and default key info
verify_table_data($node_primary, $dbname, "101|James Bond");
verify_default_key_info($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# Rotate Vault key
set_global_default_key($node_primary, $dbname, 'default_global_vault_key2', $VAULT_PRO);
verify_table_data($node_primary, $dbname, "101|James Bond");
verify_default_key_info($node_primary, $dbname, 'default_global_vault_key2', $VAULT_PRO);

# Add and set KMIP key provider
add_global_key_provider($node_primary, $dbname, $KMIP_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
));
set_global_default_key($node_primary, $dbname, 'default_global_kmip_key2', $KMIP_PRO);

# Verify table data and default key info after KMIP key rotation
verify_table_data($node_primary, $dbname, "101|James Bond");
verify_default_key_info($node_primary, $dbname, 'default_global_kmip_key2', $KMIP_PRO);

# Add and set File key provider
add_global_key_provider($node_primary, $dbname, $FILE_PRO, sprintf(
    "SELECT pg_tde_add_global_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
));
set_global_default_key($node_primary, $dbname, 'default_global_file_key2', $FILE_PRO);

# Verify table data and default key info after File key rotation
verify_table_data($node_primary, $dbname, "101|James Bond");
verify_default_key_info($node_primary, $dbname, 'default_global_file_key2', $FILE_PRO);

# Restart the server and verify table data and default key info
diag("Restarting the server...");
$node_primary->restart;
verify_table_data($node_primary, $dbname, "101|James Bond");
verify_default_key_info($node_primary, $dbname, 'default_global_file_key2', $FILE_PRO);

done_testing();

# ===== subroutines =====

# Subroutine to add a global key provider
sub add_global_key_provider {
    my ($node, $db, $provider_name, $setup_sql) = @_;
    my $result = invoke_add_key_provider_function($node, $db, $provider_name, $setup_sql);
    ok($result, "$provider_name global key provider created successfully");
}

# Subroutine to set a global default key
sub set_global_default_key {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $result = invoke_add_key_function($node, $db, 'pg_tde_set_default_key_using_global_key_provider', $key_name, $provider_name);
    ok($result, "$key_name default global Key was set successfully using provider $provider_name");
}

# Subroutine to verify table data
sub verify_table_data {
    my ($node, $db, $expected_data) = @_;
    my $result = $node->safe_psql($db, "SELECT * FROM t1;");
    chomp($result);
    is($result, $expected_data, "Table data is as expected: $result");
}

# Subroutine to verify default key info
sub verify_default_key_info {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $key_info = $node->safe_psql($db, "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
    like($key_info, qr/^$key_name\|$provider_name$/, "Default key and provider are correct");
}