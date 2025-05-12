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

ensure_database_exists_and_accessible($node_primary, 'db1');
ensure_database_exists_and_accessible($node_primary, 'db2');
$node_primary->safe_psql('db1', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql('db2', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring', '$KMIP_URL', $KMIP_PORT,
    '$KMIP_SERVER_CA', '$KMIP_SERVER_CLIENT_KEY');"
    );
$node_primary->safe_psql('db1', 
    "SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring', '$VAULT_TOKEN', '$VAULT_SERVER_URL', '$VAULT_SECRET_MOUNT_POINT', NULL);"
    );

# Trying to create Principal Key using a key provider outside the scope of db2. Must fail"
my $error;
eval {
    $node_primary->safe_psql('db2',
        "SELECT pg_tde_set_key_using_database_key_provider('vault_key1','vault_keyring');");
    1;
} or $error = $@;

like($error, qr/key provider "vault_keyring" does not exists/,
    "Fails with expected error for missing provider 'vault_keyring'")
    or diag("Error: $error");

# Creating Principal key using database key provider. Must pass"
$error = undef;
my $result;

eval {
    $result = $node_primary->safe_psql('db1',
        "SELECT pg_tde_set_key_using_database_key_provider('vault_key1','vault_keyring');");
    chomp($result);
    1;
} or $error = $@;

ok(!$error, "Key was set successfully using provider 'vault_keyring'")
    or diag("Error: $error");

$node_primary->safe_psql($DB_NAME, "drop database db1;");
$node_primary->safe_psql($DB_NAME, "drop database db2;");

done_testing();
