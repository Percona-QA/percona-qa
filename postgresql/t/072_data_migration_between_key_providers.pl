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
my $dbname_new = 'test_db_new';
my $KMIP_PRO = 'kmip_keyring8';
my $VAULT_PRO = 'vault_keyring8';
my $FILE_PRO = 'file_keyring8';
my $KMIP_KEY = 'kmip_key8';
my $VAULT_KEY = 'vault_key8';
my $FILE_KEY = 'file_key8';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';
my $dump_file = "$PostgreSQL::Test::Utils::tmp_check/t1_t2_dump.sql";

# ====== STEP 2: Ensure Databases Exist and Enable pg_tde ======
diag("Ensuring databases exist and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");
ensure_database_exists_and_accessible($node_primary, $dbname_new);
$node_primary->safe_psql($dbname_new, "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Add and Set Vault Key Provider ======
diag("Adding Vault key provider and setting default encryption key");
add_key_provider($node_primary, $dbname, $VAULT_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_vault_v2('%s', '%s', '%s', '%s', NULL);",
    $VAULT_PRO, $VAULT_TOKEN, $VAULT_SERVER_URL, $VAULT_SECRET_MOUNT_POINT
));
set_key($node_primary, $dbname, $VAULT_KEY, $VAULT_PRO);

# ====== STEP 4: Create and Populate Tables ======
diag("Creating and populating tables in the source database");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
CREATE TABLE t2(a INT PRIMARY KEY, b VARCHAR) USING heap;
INSERT INTO t1 VALUES (101, 'James Bond');
INSERT INTO t2 VALUES (101, 'James Bond');
SQL

# ====== STEP 5: Add and Set File Key Provider ======
diag("Adding File key provider and setting encryption key for the target database");
add_key_provider($node_primary, $dbname_new, $FILE_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_file('%s', '/tmp/keyring.file');",
    $FILE_PRO
));
set_key($node_primary, $dbname_new, $FILE_KEY, $FILE_PRO);

# ====== STEP 6: Dump and Restore Tables ======
diag("Dumping tables from the source database and restoring them into the target database");
$node_primary->run_log(['pg_dump', '-d', $dbname, '-t', 't1', '-t', 't2', '-f', $dump_file]);
ok(-e $dump_file, 'pg_dump created dump file');
$node_primary->command_ok(['psql', '-d', $dbname_new, '-f', $dump_file], 'Restored dump into new DB');

# ====== STEP 7: Verify Table Data and Key Info ======
diag("Verifying table data and key information in the target database");
verify_table_data($node_primary, $dbname_new, 't1', "101|James Bond", $TDE_HEAP);
verify_table_data($node_primary, $dbname_new, 't2', "101|James Bond", $HEAP);
verify_key_info($node_primary, $dbname_new, $FILE_KEY, $FILE_PRO);

# ====== STEP 8: Restart Node and Verify ======
diag("Restarting node and verifying table data and key information");
$node_primary->restart;
verify_table_data($node_primary, $dbname_new, 't1', "101|James Bond", $TDE_HEAP);
verify_table_data($node_primary, $dbname_new, 't2', "101|James Bond", $HEAP);
verify_key_info($node_primary, $dbname_new, $FILE_KEY, $FILE_PRO);

# ====== STEP 9: Rotate Key and Verify ======
diag("Rotating encryption key and verifying key information");
set_key($node_primary, $dbname_new, 'file_key2', $FILE_PRO);
verify_key_info($node_primary, $dbname_new, 'file_key2', $FILE_PRO);

# ====== STEP 10: Add and Set KMIP Key Provider ======
diag("Adding KMIP key provider and setting encryption key");
add_key_provider($node_primary, $dbname_new, $KMIP_PRO, sprintf(
    "SELECT pg_tde_add_database_key_provider_kmip('%s', '%s', %d, '%s', '%s');",
    $KMIP_PRO, $KMIP_URL, $KMIP_PORT, $KMIP_SERVER_CA, $KMIP_SERVER_CLIENT_KEY
));
set_key($node_primary, $dbname_new, $KMIP_KEY, $KMIP_PRO);

# ====== STEP 11: Restart Node and Final Verification ======
diag("Restarting node and performing final verification of table data and key information");
$node_primary->restart;
verify_table_data($node_primary, $dbname_new, 't1', "101|James Bond", $TDE_HEAP);
verify_table_data($node_primary, $dbname_new, 't2', "101|James Bond", $HEAP);
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

# Subroutine to verify table data and access method
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