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

$node_primary->append_conf('postgresql.conf', q{
    listen_addresses = '*'
    logging_collector = on
    log_directory = 'log'
    log_filename = 'server.log'
    log_statement = 'all'
});
$node_primary->start;

# Common variables
my $dbname = 'test_db';
my $FILE_PRO = 'file_keyring1';
my $FILE_KEY = 'file_key1';
my $TDE_HEAP = 't'; # used for tde_heap access method verification
my $HEAP = 'f';
my $dump_file = "$PostgreSQL::Test::Utils::tmp_check/dump_file.sql";

# ====== STEP 2: Create pg_tde extension in template1 ======
diag("Creating pg_tde extension in template1");
$node_primary->safe_psql('template1', "CREATE EXTENSION pg_tde;");

# ====== STEP 3: Create a New Database from template1 ======
diag("Creating a new database 'new_db1' from template1");

# Create the new database
$node_primary->safe_psql('postgres', "CREATE DATABASE new_db1 TEMPLATE template1;");

# Verify pg_tde extension exists in the new database
my $extension_exists = $node_primary->safe_psql('new_db1', "SELECT 1 FROM pg_extension WHERE extname = 'pg_tde';");
is($extension_exists, '1', "pg_tde extension exists in the new database 'new_db'");

# ===== STEP 4: Create a New Database from template0 without TDE ======
diag("Creating a new database 'new_db2' from template0 without TDE");
# Create the new database
$node_primary->safe_psql('postgres', "CREATE DATABASE new_db2 TEMPLATE template0;");
# Verify pg_tde extension does not exist in the new database
$extension_exists = $node_primary->safe_psql('new_db2', "SELECT 1 FROM pg_extension WHERE extname = 'pg_tde';");
is($extension_exists, '', "pg_tde extension does not exist in the new database 'new_db2'");

# ====== STEP 5: Create a New Database from custom template with TDE ======
diag("Creating custom template with TDE");
$node_primary->safe_psql('postgres', "CREATE DATABASE custom_template;");

# Create the new database
$node_primary->safe_psql('postgres', "CREATE DATABASE new_db3 TEMPLATE custom_template;");
# Verify pg_tde extension exists in the new database
$extension_exists = $node_primary->safe_psql('new_db3', "SELECT 1 FROM pg_extension WHERE extname = 'pg_tde';");
is($extension_exists, '1', "pg_tde extension exists in the new database 'new_db3'");

# ====== STEP 6: Call TDE functions with new database ======
diag("Creating and populating table enc_test using TDE");
add_key_provider($node_primary, 'new_db1', $FILE_PRO, 'file', "SELECT pg_tde_add_database_key_provider_file('$FILE_PRO', '/tmp/keyring.file');");
set_key($node_primary, 'new_db1', $FILE_KEY, $FILE_PRO, 'database_key', 'pg_tde_create_key_using_database_key_provider');
set_key($node_primary, 'new_db1', $FILE_KEY, $FILE_PRO, 'database_key', 'pg_tde_set_key_using_database_key_provider');
$node_primary->safe_psql('new_db1', <<'SQL');
CREATE TABLE enc_test(id INT, secret TEXT) USING tde_heap;
INSERT INTO enc_test VALUES (1, 'secret_text');
SQL
verify_table_data($node_primary, 'new_db1', 'enc_test', "1|secret_text", $TDE_HEAP);


# ====== STEP 7: Drop extension from new_db1 with encrypted table ======
diag("Dropping pg_tde extension from new_db1 with encrypted table (should fail if dependencies exist)");
# Check for dependent objects
my $depend_count = $node_primary->safe_psql('new_db1', "SELECT count(*) FROM pg_depend WHERE objid IN (SELECT oid FROM pg_extension WHERE extname='pg_tde');");

if ($depend_count > 0) {
    diag("Dependent objects exist for pg_tde extension. Attempting to drop should fail.");
    my $result = $node_primary->psql('new_db1', "DROP EXTENSION pg_tde;");
    ok($result != 0, "pg_tde extension drop failed as expected because of dependent objects");
} else {
    diag("No dependent objects exist for pg_tde extension. Attempting to drop should succeed.");
    my $result = $node_primary->safe_psql('new_db1', "DROP EXTENSION pg_tde;");
    is($result, '1', "pg_tde extension dropped successfully as there are no dependent objects");
}
# ====== STEP 8: Create a limited user ======
diag("Creating a limited user, non-superuser");
$node_primary->safe_psql('postgres', "CREATE ROLE limited_user LOGIN PASSWORD 'password' NOINHERIT;");
$node_primary->safe_psql('postgres', "CREATE DATABASE new_db4 WITH OWNER limited_user;");
# Check if pg_tde extension exists in the new database
$extension_exists = $node_primary->safe_psql('new_db4', "SELECT 1 FROM pg_extension WHERE extname = 'pg_tde';");
is($extension_exists, '1', "pg_tde extension does not exist in the new database 'new_db4'");

# ====== STEP 9: Drop pg_tde extension from template1 ======
diag("Dropping pg_tde extension from template1");
$node_primary->safe_psql('template1', "DROP EXTENSION pg_tde;");

# ====== STEP 10: Create a new database from template1 ======
diag("Creating a new database 'new_db5' from template1, should not have pg_tde");
$node_primary->safe_psql('postgres', "CREATE DATABASE new_db5 TEMPLATE template1;");
# Verify pg_tde extension does not exist in the new database
$extension_exists = $node_primary->safe_psql('new_db5', "SELECT 1 FROM pg_extension WHERE extname = 'pg_tde';");
is($extension_exists, '', "pg_tde extension does not exist in the new database 'new_db5'");

# ====== STEP 11: Check system catalogs in new_db1 ======
diag("Checking system catalogs in new_db1");;
$extension_exists = $node_primary->safe_psql('new_db1', "SELECT extname FROM pg_extension WHERE extname='pg_tde'");
is($extension_exists, 'pg_tde', "pg_tde extension is installed");

$depend_count = $node_primary->safe_psql('new_db1', "SELECT count(*) FROM pg_depend WHERE objid IN (SELECT oid FROM pg_extension WHERE extname='pg_tde')");
ok($depend_count > 0, "pg_tde has dependent objects registered");

# ======= STEP 12: Check extension in dump schema catalogs in new_db2 ======
diag("Checking pg_tde extension in dump schema catalogs in new_db2");
# Run pg_dump to generate the schema-only dump
$node_primary->command_ok(['pg_dump', '-s', 'new_db1', '-f', $dump_file], 'pg_dump ran successfully');
ok(-e $dump_file, 'pg_dump created dump file');

# Read the contents of the dump file
open my $fh, '<', $dump_file or die "Could not open dump file: $!";
my $dump_content = do { local $/; <$fh> };
close $fh;

# Check if pg_tde is mentioned in the schema dump
like($dump_content, qr/pg_tde/, "pg_tde is found in pg_dump schema output");

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
