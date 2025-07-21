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

unlink('/tmp/keyring.file');
# Create a new database if not exists
ensure_database_exists_and_accessible($node_primary, $DB_NAME);
$node_primary->safe_psql($DB_NAME, "CREATE EXTENSION pg_tde;");

#diag("Creating global KMIP provider");
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring2','$KMIP_URL',$KMIP_PORT,
    '$KMIP_SERVER_CA','$KMIP_SERVER_CLIENT_KEY');"
    );
#diag("Creating global vault provider");
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_vault_v2('vault_keyring2', '$VAULT_TOKEN', '$VAULT_SERVER_URL', '$VAULT_SECRET_MOUNT_POINT', NULL);"
    );
#diag("Creating global file provider");
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_file('file_keyring2', '/tmp/keyring.file');"
    );

# diag("Creating databases db1, db2, db3");
ensure_database_exists_and_accessible($node_primary, 'db1');
ensure_database_exists_and_accessible($node_primary, 'db2');
ensure_database_exists_and_accessible($node_primary, 'db3');

# diag("Creating databases db1, db2, db3");
$node_primary->safe_psql('db1', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql('db2', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql('db3', "CREATE EXTENSION pg_tde;");

# diag("Set Principal Keys for db1, db2, db3");
$node_primary->safe_psql('db1', "SELECT pg_tde_create_key_using_global_key_provider('vault_key2', 'vault_keyring2');");
$node_primary->safe_psql('db1', "SELECT pg_tde_set_key_using_global_key_provider('vault_key2', 'vault_keyring2');");
$node_primary->safe_psql('db2', "SELECT pg_tde_create_key_using_global_key_provider('kmip_key2', 'kmip_keyring2');");
$node_primary->safe_psql('db2', "SELECT pg_tde_set_key_using_global_key_provider('kmip_key2', 'kmip_keyring2');");
$node_primary->safe_psql('db3', "SELECT pg_tde_create_key_using_global_key_provider('file_key2', 'file_keyring2');");
$node_primary->safe_psql('db3', "SELECT pg_tde_set_key_using_global_key_provider('file_key2', 'file_keyring2');");

# diag("Create tables in db1, db2, db3");
$node_primary->safe_psql('db1', "CREATE TABLE t1(a INT) USING tde_heap;");
$node_primary->safe_psql('db2', "CREATE TABLE t2(a INT) USING tde_heap;");
$node_primary->safe_psql('db3', "CREATE TABLE t3(a INT) USING tde_heap;");
$node_primary->safe_psql('db1', "INSERT INTO t1 SELECT generate_series(1, 100);");
$node_primary->safe_psql('db2', "INSERT INTO t2 SELECT generate_series(1, 50);");
$node_primary->safe_psql('db3', "INSERT INTO t3 SELECT generate_series(1, 300);");
my %before_restart;
my %after_restart;

# Capture counts before restart
foreach my $db (qw/db1 db2 db3/) {
    my $table = $db;
    $table =~ s/db/t/;  # derive table name (e.g., db1 -> t1)
    my $result = $node_primary->safe_psql($db, "SELECT COUNT(*) FROM $table");
    chomp($result);
    $before_restart{$db} = $result;
    #diag("Before restart - $db.$table: $result rows");
}

# Restart the server
$node_primary->restart;

# Capture counts after restart and compare
foreach my $db (qw/db1 db2 db3/) {
    my $table = $db;
    $table =~ s/db/t/;
    my $result = $node_primary->safe_psql($db, "SELECT COUNT(*) FROM $table");
    chomp($result);
    $after_restart{$db} = $result;
    #diag("After restart - $db.$table: $result rows");

    is($after_restart{$db}, $before_restart{$db}, "Row count in $db.$table is unchanged after restart. $result");
}


$node_primary->safe_psql($DB_NAME, "DROP DATABASE db1;");
$node_primary->safe_psql($DB_NAME, "DROP DATABASE db2;");
$node_primary->safe_psql($DB_NAME, "DROP DATABASE db3;");

done_testing();
