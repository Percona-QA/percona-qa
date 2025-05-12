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

# "Creating databases test1, test2
ensure_database_exists_and_accessible($node_primary, 'test1');
ensure_database_exists_and_accessible($node_primary, 'test2');

# "Creating pg_tde extension in test1, test2"
$node_primary->safe_psql('test1', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql('test2', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql('test1', 
    "SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring3', '$VAULT_TOKEN', '$VAULT_SERVER_URL', '$VAULT_SECRET_MOUNT_POINT', NULL);"
    );
$node_primary->safe_psql('test1', 
    "SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring3_can_delete', '$VAULT_TOKEN', '$VAULT_SERVER_URL', '$VAULT_SECRET_MOUNT_POINT', NULL);"
    );
$node_primary->safe_psql('test1',
        "SELECT pg_tde_set_key_using_database_key_provider('vault_key3','vault_keyring3');");
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring3', '$KMIP_URL', $KMIP_PORT,
    '$KMIP_SERVER_CA', '$KMIP_SERVER_CLIENT_KEY');"
    );
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_kmip('kmip_keyring3_can_delete', '$KMIP_URL', $KMIP_PORT,
    '$KMIP_SERVER_CA', '$KMIP_SERVER_CLIENT_KEY');"
    );
$node_primary->safe_psql($DB_NAME, "SELECT pg_tde_set_default_key_using_global_key_provider('kmip_key3', 'kmip_keyring3');");

$node_primary->safe_psql('test1', "CREATE TABLE t1(a INT) USING tde_heap;");
$node_primary->safe_psql('test2', "CREATE TABLE t2(a INT) USING tde_heap;");
$node_primary->safe_psql('test1', "INSERT INTO t1 SELECT generate_series(1, 80);");
$node_primary->safe_psql('test2', "INSERT INTO t2 SELECT generate_series(1, 70);");

my %before_restart;
my %after_restart;

foreach my $db (qw/test1 test2/) {
    my $table = $db;
    $table =~ s/test/t/;  # derive table name (e.g., test1 -> t1)
    my $result = $node_primary->safe_psql($db, "SELECT COUNT(*) FROM $table");
    chomp($result);
    $before_restart{$db} = $result;
    #diag("Before restart - $db.$table: $result rows");
}

# Restart the server
$node_primary->restart;

# Capture counts after restart and compare
foreach my $db (qw/test1 test2/) {
    my $table = $db;
    $table =~ s/test/t/;
    my $result = $node_primary->safe_psql($db, "SELECT COUNT(*) FROM $table");
    chomp($result);
    $after_restart{$db} = $result;
    #diag("After restart - $db.$table: $result rows");

    is($after_restart{$db}, $before_restart{$db}, "Row count in $db.$table is unchanged after restart. $result");
}

# List all Key providers
# Check local/database key providers
my $local_providers = $node_primary->safe_psql(
    'test1',
    "SELECT provider_name, provider_type FROM pg_tde_list_all_database_key_providers();"
);
#diag("Database Key Providers:\n$local_providers");

like(
    $local_providers,
    qr/\bvault_keyring3\b/,
    "Database provider 'vault_keyring3' exists"
);

like(
    $local_providers,
    qr/\bvault_keyring3_can_delete\b/,
    "Database provider 'vault_keyring3_can_delete' exists"
);

# Check global key providers
my $global_providers = $node_primary->safe_psql(
    $DB_NAME,
    "SELECT provider_name, provider_type FROM pg_tde_list_all_global_key_providers();"
);
#diag("Global Key Providers:\n$global_providers");

like(
    $global_providers,
    qr/\bkmip_keyring3\b/,
    "Global provider 'kmip_keyring3' exists"
);

like(
    $global_providers,
    qr/\bkmip_keyring3_can_delete\b/,
    "Global provider 'kmip_keyring3_can_delete' exists"
);


foreach my $db (qw/test1 test2/) {
    my $table = $db;
    $table =~ s/test/t/;
    my $result = $node_primary->safe_psql($db, "SELECT COUNT(*) FROM $table");
    chomp($result);
    $after_restart{$db} = $result;
    #diag("After restart - $db.$table: $result rows");

    is($after_restart{$db}, $before_restart{$db}, "Row count in $db.$table is unchanged after restart. $result");
}

# Drop tables from both databases
$node_primary->safe_psql('test1', "DROP table t1;");
$node_primary->safe_psql('test2', "DROP table t2;");
$node_primary->restart;
# Trying to delete a key provider which is currently in use. Must fail"
my $error;
eval {
    $node_primary->safe_psql('test1',
        "SELECT pg_tde_delete_database_key_provider('vault_keyring3');");
    1;
} or $error = $@;

like($error, qr/Can't delete a provider which is currently in use/,
    "Fails to delete a database provider currently in use. 'vault_keyring'")
    or diag("Error: $error");

eval {
    $node_primary->safe_psql('test2',
        "SELECT pg_tde_delete_global_key_provider('kmip_keyring3');");
    1;
} or $error = $@;

like($error, qr/Can't delete a provider which is currently in use/,
    "Fails to delete global provider currently in use. 'vault_keyring'")
    or diag("Error: $error");

# Deleting provider which are not in use. Must pass"
$error = undef;
my $result;

eval {
    $result = $node_primary->safe_psql('test1',
        "SELECT pg_tde_delete_database_key_provider('vault_keyring3_can_delete');");
    chomp($result);
    1;
} or $error = $@;

ok(!$error, "Database provider successfully deleted. provider name: 'vault_keyring3_can_delete'")
    or diag("Error: $error");

eval {
    $result = $node_primary->safe_psql('test1',
        "SELECT pg_tde_delete_global_key_provider('kmip_keyring3_can_delete');");
    chomp($result);
    1;
} or $error = $@;

ok(!$error, "Global provider successfully deleted. provider name: 'kmip_keyring3_can_delete'")
    or diag("Error: $error");

# Restart the server
$node_primary->restart;

# List all Key providers
my $local_providers_after_delete  = $node_primary->safe_psql('test1',
    "SELECT provider_name, provider_type FROM pg_tde_list_all_database_key_providers();");
unlike(
    $local_providers_after_delete,
    qr/vault_keyring3_can_delete/,
    "Local provider 'vault_keyring3_can_delete' has been deleted"
);

my $global_providers_after_delete = $node_primary->safe_psql('test2',
    "SELECT provider_name, provider_type FROM pg_tde_list_all_global_key_providers();");
unlike(
    $global_providers_after_delete,
    qr/vault_keyring3_can_delete/,
    "Global provider 'vault_keyring3_can_delete' has been deleted"
);

# Try deleting a non-existent global provider and expect an error
eval {
    $node_primary->safe_psql('test1', "SELECT pg_tde_delete_database_key_provider('vault_keyring3_not_exists');");
    1;
} or $error = $@;

like(
    $error,
    qr/key provider "vault_keyring3_not_exists" does not exists/,
    "Fails with expected error when deleting non-existent database provider 'vault_keyring3_not_exists'"
) or diag("Unexpected error: $error");

$error = undef; # Reset error before next eval
eval {
    $node_primary->safe_psql('test1', "SELECT pg_tde_delete_global_key_provider('kmip_keyring3_not_exists');");
    1;
} or $error = $@;

like(
    $error,
    qr/key provider "kmip_keyring3_not_exists" does not exists/,
    "Fails with expected error when deleting non-existent global provider 'kmip_keyring3_not_exists'"
) or diag("Unexpected error: $error");

done_testing();
