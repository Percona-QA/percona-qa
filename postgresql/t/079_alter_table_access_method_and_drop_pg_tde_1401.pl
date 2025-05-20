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
#set_default_table_am_tde_heap($node_primary);

$node_primary->append_conf('postgresql.conf', "listen_addresses = '*'");
$node_primary->start;

# Common variables
my $dbname = 'test_db';
my $FILE_PRO = 'file_provider1';
my $FILE_KEY = 'file_key1';

# ====== STEP 2: Ensure Database Exists and Enable pg_tde ======
diag("Ensuring database exists and enabling pg_tde extension");
ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

diag("Adding FILE global key provider and setting encryption key");
$node_primary->safe_psql($dbname, 
    "SELECT pg_tde_add_global_key_provider_file('$FILE_PRO', '/tmp/keyring.file');"
    );
$node_primary->safe_psql($dbname, 
    "SELECT pg_tde_set_key_using_global_key_provider('$FILE_KEY', '$FILE_PRO');");

# ====== STEP 4: Create and Populate Table ======
diag("Creating and populating table t1");
$node_primary->safe_psql($dbname, <<'SQL');
CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;
INSERT INTO t1 VALUES (101, 'James Bond');
SQL

# Verify table contents
is($node_primary->safe_psql($dbname, "SELECT * FROM t1;"), "101|James Bond", "Table t1 contents are as expected");
is($node_primary->safe_psql($dbname, "SELECT pg_tde_is_encrypted('t1');"), 't', "Table t1 is encrypted");

# ====== STEP 5: Alter Table Access Method to Heap ======
diag("Altering table access method to heap");
$node_primary->safe_psql($dbname, "ALTER TABLE t1 SET ACCESS METHOD heap;");
is($node_primary->safe_psql($dbname, "SELECT * FROM t1;"), "101|James Bond", "Table t1 contents are as expected");
is($node_primary->safe_psql($dbname, "SELECT pg_tde_is_encrypted('t1');"), 'f', "Table t1 is not encrypted");

# ====== STEP 6: Drop pg_tde Extension ======
diag("Dropping pg_tde extension");
my $result = $node_primary->safe_psql($dbname, "DROP EXTENSION pg_tde;");
is($result, '', "pg_tde extension dropped successfully as there are no dependent objects");
my $extension_exists = $node_primary->safe_psql($dbname, "SELECT 1 FROM pg_extension WHERE extname = 'pg_tde';");
is($extension_exists, '', "pg_tde extension does not exist in the database");

$extension_exists = $node_primary->safe_psql($dbname, "\\dx");
diag("pg_extension list: $extension_exists");

# ====== STEP 7: Remove pg_tde from postgresql.conf ======
diag("Removing pg_tde from shared_preload_libraries");
$node_primary->adjust_conf('postgresql.conf', "shared_preload_libraries', ''");
$node_primary->restart;

# ====== STEP 8: Verify table data ======
diag("Verifying table data after server restart");
is($node_primary->safe_psql($dbname, "SELECT * FROM t1;"), "101|James Bond", "Table t1 contents are as expected");

done_testing();