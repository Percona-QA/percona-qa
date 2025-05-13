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
my $dbname_new = 'test_db_new';
my $KMIP_PRO = 'kmip_keyring8';
my $VAULT_PRO = 'vault_keyring8';
my $FILE_PRO = 'file_keyring8';
my $KMIP_KEY = 'kmip_key8';
my $VAULT_KEY = 'vault_key8';
my $FILE_KEY = 'file_key8';
my $dump_file = "$PostgreSQL::Test::Utils::tmp_check/t1_t2_dump.sql";


# Ensure databases exist and create pg_tde extension
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");
ensure_database_exists_and_accessible($node_primary, $dbname_new);
$node_primary->safe_psql($dbname_new, "CREATE EXTENSION pg_tde;");

# Add and set Vault key provider
add_key_provider($node_primary, $dbname, $VAULT_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));
set_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# Create and populate tables
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING heap;
INSERT INTO t1 VALUES (101, 'James Bond');
INSERT INTO t2 VALUES (101, 'James Bond');
SQL

# Add and set File key provider
add_key_provider($node_primary, $dbname_new, $FILE_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
));
set_key($node_primary, $dbname_new, $FILE_KEY, $FILE_PRO);

# Dump and restore tables
$node_primary->run_log(['pg_dump', '-d', $dbname, '-t', 't1', '-t', 't2', '-f', $dump_file]);
ok(-e $dump_file, 'pg_dump created dump file');
$node_primary->command_ok(['psql', '-d', $dbname_new, '-f', $dump_file], 'Restored dump into new DB');

# Verify table data and key info
verify_table_data($node_primary, $dbname_new, 't1', "101|James Bond");
verify_table_data($node_primary, $dbname_new, 't2', "101|James Bond");
verify_key_info($node_primary, $dbname_new, $FILE_KEY, $FILE_PRO);

# Restart node and verify
diag("Restarting node...");
$node_primary->restart;

# Verify table data and key info after restart
verify_table_data($node_primary, $dbname_new, 't1', "101|James Bond");
verify_table_data($node_primary, $dbname_new, 't2', "101|James Bond");
verify_key_info($node_primary, $dbname_new, $FILE_KEY, $FILE_PRO);

# Rotate key and verify
set_key($node_primary, $dbname_new, 'file_key2', $FILE_PRO);
verify_key_info($node_primary, $dbname_new, 'file_key2', $FILE_PRO);

# Add and set KMIP key provider
add_key_provider($node_primary, $dbname_new, $KMIP_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
));
set_key($node_primary, $dbname_new, $KMIP_KEY, $KMIP_PRO);

# Restart node and verify
diag("Restarting node...");
$node_primary->restart;

# Final verification
verify_table_data($node_primary, $dbname_new, 't1', "101|James Bond");
verify_table_data($node_primary, $dbname_new, 't2', "101|James Bond");
verify_key_info($node_primary, $dbname_new, $KMIP_KEY, $KMIP_PRO);

done_testing();

# ====== SUBROUTINES ======
# Subroutine to add a key provider
sub add_key_provider {
    my ($node, $db, $provider_name, $setup_sql) = @_;
    my $result = invoke_add_key_provider_function($node, $db, $provider_name, $setup_sql);
    ok($result, "$provider_name database key provider created successfully");
}

# Subroutine to set a key
sub set_key {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $result = invoke_add_key_function($node, $db, 'pg_tde_set_key_using_database_key_provider', $key_name, $provider_name);
    ok($result, "$key_name database key was set successfully using provider $provider_name");
}

# Subroutine to verify table data
sub verify_table_data {
    my ($node, $db, $table, $expected_data) = @_;
    my $result = $node->safe_psql($db, "SELECT * FROM $table;");
    chomp($result);
    is($result, $expected_data, "Table $table contents are as expected: $result");
}

# Subroutine to verify key info
sub verify_key_info {
    my ($node, $db, $key_name, $provider_name) = @_;
    my $key_info = $node->safe_psql($db, "SELECT key_name, key_provider_name FROM pg_tde_key_info();");
    like($key_info, qr/^$key_name\|$provider_name$/, "Key info is correct");
}
