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

# Create a new database if not exists
ensure_database_exists_and_accessible($node_primary, $DB_NAME);
$node_primary->safe_psql($DB_NAME, "CREATE EXTENSION pg_tde;");

# Common variables
my $dbname = 'test_db';
my $KMIP_PRO = 'kmip_keyring7';
my $VAULT_PRO = 'vault_keyring7';
my $FILE_PRO = 'file_keyring7';
my $KMIP_KEY = 'kmip_key7';
my $VAULT_KEY = 'vault_key7';
my $FILE_KEY = 'file_key7';


ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# Global Vault_v2 provider
my $setup_sql_vault = sprintf(
    "SELECT pg_tde_add_global_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
);

my $vault_result = invoke_add_key_provider_function($node_primary, $dbname, $VAULT_PRO, $setup_sql_vault);
ok($vault_result, "$VAULT_PRO global key provider created successfully");

# Add a default global key using the vault provider
my $key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_default_key_using_global_key_provider', $VAULT_KEY, $VAULT_PRO);
ok($key_result, "$VAULT_KEY default global Key was set successfully using provider $VAULT_PRO");

# Create a table using the global Vault provider
eval {
    $node_primary->safe_psql($dbname,
        "CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;");
    $node_primary->safe_psql($dbname,
        "INSERT INTO t1 VALUES (101, 'James Bond');");
    1;
} or do {
    fail("Table operations failed: $@");
    return;
};

# Verify the table data
my $result = $node_primary->safe_psql($dbname, "SELECT * FROM t1;");
chomp($result);
is($result, "101|James Bond", "Table contents are as expected: $result");

# Verify the default key info
my $default_key_info = $node_primary->safe_psql($dbname, "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^$VAULT_KEY\|$VAULT_PRO$/, "Default key and provider are correct");

# Rotate the Global Default Principal Key
$key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_default_key_using_global_key_provider', 'default_global_vault_key2', $VAULT_PRO);
ok($key_result, "default_global_vault_key2 default global Key was set successfully using provider $VAULT_PRO");

# Verify the table data after key rotation
$result = $node_primary->safe_psql($dbname, "SELECT * FROM t1;");
chomp($result);
is($result, "101|James Bond", "Table contents after key rotation are as expected: $result");

# Verify the default key info
$default_key_info = $node_primary->safe_psql($dbname, "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^default_global_vault_key2\|$VAULT_PRO$/, "Default key and provider are correct");

# Change Global Key Provider to kmip
my $setup_sql_kmip = sprintf(
    "SELECT pg_tde_add_global_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $KMIP_PRO, $setup_sql_kmip);
ok($vault_result, "$KMIP_PRO global key provider created successfully");

# Rotate the Global Default Principal Key
$key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_default_key_using_global_key_provider', 'default_global_kmip_key2', $KMIP_PRO);
ok($key_result, "default_global_kmip_key2 default global Key was set successfully using provider $KMIP_PRO");

# Verify the table data after key rotation
$result = $node_primary->safe_psql($dbname, "SELECT * FROM t1;");
chomp($result);
is($result, "101|James Bond", "Table data is correct after change key provider and key rotation, are as expected: $result");

# Verify the default key info
$default_key_info = $node_primary->safe_psql($dbname, "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^default_global_kmip_key2\|$KMIP_PRO$/, "Default key and provider are correct");

# Change Global Key Provider to file
my $setup_sql_file = sprintf(
    "SELECT pg_tde_add_global_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $FILE_PRO, $setup_sql_file);
ok($vault_result, "$FILE_PRO global key provider created successfully");

# Rotate the Global Default Principal Key
$key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_default_key_using_global_key_provider', 'default_global_file_key2', $FILE_PRO);
ok($key_result, "default_global_file_key2 default global Key was set successfully using provider $FILE_PRO");

# Verify the table data after key rotation
$result = $node_primary->safe_psql($dbname, "SELECT * FROM t1;");
chomp($result);
is($result, "101|James Bond", "Table data is correct after change key provider are as expected: $result");

# Verify the default key info
$default_key_info = $node_primary->safe_psql($dbname, "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^default_global_file_key2\|$FILE_PRO$/, "Default key and provider are correct");

# Restart the server
$node_primary->restart;

# Verify the table data after server restart
$result = $node_primary->safe_psql($dbname, "SELECT * FROM t1;");
chomp($result);
is($result, "101|James Bond", "Table data is correct after server restart are as expected: $result");

# Verify the default key info
$default_key_info = $node_primary->safe_psql($dbname, "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^default_global_file_key2\|file_keyring7$/, "Default key and provider are correct");

done_testing();
