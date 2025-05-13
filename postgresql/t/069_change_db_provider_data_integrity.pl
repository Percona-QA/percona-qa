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
my $KMIP_PRO = 'kmip_keyring6';
my $VAULT_PRO = 'vault_keyring6';
my $FILE_PRO = 'file_keyring6';
my $KMIP_KEY = 'kmip_key6';
my $VAULT_KEY = 'vault_key6';
my $FILE_KEY = 'file_key6';


ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

# Database FILE provider
my $setup_sql_file = sprintf(
    "SELECT pg_tde_add_database_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
);
my $vault_result = invoke_add_key_provider_function($node_primary, $dbname, $FILE_PRO, $setup_sql_file);
ok($vault_result, "$FILE_PRO database key provider created successfully");

# Database KMIP provider
my $setup_sql_kmip = sprintf(
    "SELECT pg_tde_add_database_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $KMIP_PRO, $setup_sql_kmip);
ok($vault_result, "$KMIP_PRO database key provider created successfully");

# Database Vault_v2 provider
my $setup_sql_vault = sprintf(
    "SELECT pg_tde_add_database_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
);

$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $VAULT_PRO, $setup_sql_vault);
ok($vault_result, "$VAULT_PRO database key provider created successfully");

# Set Principal Key using FILE provider
my $key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_key_using_database_key_provider', $FILE_KEY, $FILE_PRO);
ok($key_result, "$FILE_KEY database key was set successfully using provider $FILE_PRO");

# Create a table using the FILE provider
eval {
    $node_primary->safe_psql($dbname,
        "CREATE TABLE t1(a INT, b varchar) USING tde_heap;");
    $node_primary->safe_psql($dbname,
        "INSERT INTO t1 VALUES (200, 'Bob'), (300, 'khan');");
    1;
} or do {
    fail("Table operations failed: $@");
    return;
};

# Verify data integrity in t1
my $result = $node_primary->safe_psql($dbname, "SELECT a, b FROM t1 ORDER BY a;");
chomp($result);
is($result, "200|Bob\n300|khan", "Table contents are as expected: $result");

# Change Database KMIP provider
$setup_sql_kmip = sprintf(
    "SELECT pg_tde_change_database_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $KMIP_PRO, $setup_sql_kmip);
ok($vault_result, "$KMIP_PRO database key provider changed successfully");
$key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_key_using_database_key_provider', $KMIP_KEY, $KMIP_PRO);
ok($key_result, "$KMIP_KEY database key was set successfully using provider $KMIP_PRO");

# Create a table using the KMIP provider
eval {
    $node_primary->safe_psql($dbname,
        "CREATE TABLE t2(a INT, b varchar) USING tde_heap;");
    $node_primary->safe_psql($dbname,
        "INSERT INTO t2 VALUES (200, 'Bob'), (300, 'Yan');");
    1;
} or do {
    fail("Table operations failed: $@");
    return;
};

$result = $node_primary->safe_psql($dbname, "SELECT a, b FROM t2 ORDER BY a;");
chomp($result);
is($result, "200|Bob\n300|Yan", "Table t2 contents are as expected: $result");

# Change Database Vault_v2 provider
$setup_sql_vault = sprintf(
    "SELECT pg_tde_change_database_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
);
$vault_result = invoke_add_key_provider_function($node_primary, $dbname, $VAULT_PRO, $setup_sql_vault);
ok($vault_result, "$VAULT_PRO database key provider changed successfully");
$key_result = invoke_add_key_function($node_primary, $dbname, 'pg_tde_set_key_using_database_key_provider', $VAULT_KEY, $VAULT_PRO);
ok($key_result, "$VAULT_KEY database Key was set successfully using provider $VAULT_PRO");

eval {
    $node_primary->safe_psql($dbname,
        "CREATE TABLE t3(a INT, b varchar) USING tde_heap;");
    $node_primary->safe_psql($dbname,
        "INSERT INTO t3 VALUES (200, 'Bob'), (300, 'Percona');");
    1;
} or do {
    fail("Table operations failed: $@");
    return;
};
$result = $node_primary->safe_psql($dbname, "SELECT a, b FROM t3 ORDER BY a;");
chomp($result);
is($result, "200|Bob\n300|Percona", "Table t3 contents are as expected: $result");

 # Verify key info
my $default_key_info = $node_primary->safe_psql($dbname,
    "SELECT key_name, key_provider_name FROM pg_tde_key_info();");
like($default_key_info, qr/^$VAULT_KEY\|$VAULT_PRO$/m,
    "Database principal key info matches expected");

# Verify key presence
my $verify_result = $node_primary->safe_psql($dbname,
            "SELECT pg_tde_verify_key();");
        is($verify_result, '',
            "pg_tde_verify_key returns empty string when key is present");


# "List of Database Key Providers"
my $local_providers = $node_primary->safe_psql(
    $dbname,
    "SELECT provider_name, provider_type FROM pg_tde_list_all_database_key_providers();"
);

foreach my $table (qw/t1 t2 t3/) {
    my $result = $node_primary->safe_psql($dbname, "SELECT COUNT(*) FROM $table");
    chomp($result);
    is($result, '2', "Row count in $table is unchanged before restart. $result");
}

diag("Restarting the server...");
$node_primary->restart;

foreach my $table (qw/t1 t2 t3/) {
    my $result = $node_primary->safe_psql($dbname, "SELECT COUNT(*) FROM $table");
    chomp($result);
    is($result, '2', "Row count in $table is unchanged after restart. $result");
}

done_testing();

