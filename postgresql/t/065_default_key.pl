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

my $DB_NAME= "postgres";
my $KMIP_URL = "kmip1";
my $KMIP_PORT = 5696;
my $KMIP_SERVER_CA = "/tmp/certs/server_certificate.pem";
my $KMIP_SERVER_CLIENT_KEY = "/tmp/certs/client_key_jane_doe.pem";
my $VAULT_URL = "172.18.0.2";
my $VAULT_PORT = 8200;
my $VAULT_SERVER_URL = "http://$VAULT_URL:$VAULT_PORT";
my $VAULT_TOKEN = 'root';
my $VAULT_SECRET_MOUNT_POINT = 'secret';


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
#ensure_database_exists_and_accessible($node_primary, 'test1');
#ensure_database_exists_and_accessible($node_primary, 'test2');

# "Creating pg_tde extension in test1, test2"
#$node_primary->safe_psql('test1', "CREATE EXTENSION pg_tde;");
#$node_primary->safe_psql('test2', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql($DB_NAME, 
    "SELECT pg_tde_add_global_key_provider_file('global-prov-file', '/tmp/global-file-keyring.per');"
    );
$node_primary->safe_psql($DB_NAME, 
        "SELECT pg_tde_set_default_key_using_global_key_provider('global_default_key','global-prov-file');");

# create a new database
ensure_database_exists_and_accessible($node_primary, 'test1');
$node_primary->safe_psql('test1', "CREATE EXTENSION pg_tde;");

# Verify that the default key of global key provider is set as the default key new database
eval {
    $node_primary->safe_psql('test1', "CREATE TABLE t1(a INT) USING tde_heap;");
    $node_primary->safe_psql('test1', "INSERT INTO t1 SELECT generate_series(1, 80);");
    1;
} or diag("Failed in test1: $@");

ok(!$@, "Encrypted table created and populated successfully in test1");
is($node_primary->safe_psql('test1', "SELECT count(*) FROM t1;"), '80', "test1 row count OK");

# Check default key info
my $default_key_info = $node_primary->safe_psql('test1', "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^global_default_key\|global-prov-file$/, "Default key and provider assigned implicitly in test1 are correct");

# Verify that the default key of global key provider can be set in a new database using global key provider.
ensure_database_exists_and_accessible($node_primary, 'test2');
$node_primary->safe_psql('test2', "CREATE EXTENSION pg_tde;");
$node_primary->safe_psql('test2',
        "SELECT pg_tde_set_default_key_using_global_key_provider('global_db_default_key','global-prov-file');");

# Create and insert into encrypted table in test1 with out setting the default key provider in the test1 database
eval {
    $node_primary->safe_psql('test2', "CREATE TABLE t2(a INT) USING tde_heap;");
    $node_primary->safe_psql('test2', "INSERT INTO t2 SELECT generate_series(1, 70);");
    1;
} or diag("Failed in test2: $@");

ok(!$@, "Encrypted table created and populated successfully in test2");
is($node_primary->safe_psql('test2', "SELECT count(*) FROM t2;"), '70', "test2 row count OK");

# Check default key info
$default_key_info = $node_primary->safe_psql('test2', "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info, qr/^global_db_default_key\|global-prov-file$/, "New default key and provider assigned explicitly in test2 are correct.");
# Restart the server
$node_primary->restart;
# Check that the server key set to default key automatically if the server key is not set after restart.
$default_key_info = $node_primary->safe_psql('test2', "SELECT key_name, key_provider_name FROM pg_tde_server_key_info();");
like($default_key_info, qr/^global_db_default_key\|global-prov-file$/, "Default key set to server key automatically after server restart");

my $default_key_info_restart = $node_primary->safe_psql('test1', "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info_restart, qr/^global_db_default_key\|global-prov-file$/, "Default key and provider are correct after server restart in test1");

$default_key_info_restart = $node_primary->safe_psql('test2', "SELECT key_name, key_provider_name FROM pg_tde_default_key_info();");
like($default_key_info_restart, qr/^global_db_default_key\|global-prov-file$/, "Default key and provider are correct after server restart in test2");

done_testing();
