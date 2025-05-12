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

my @providers = (
    {
        type       => 'vault',
        name       => 'vault_keyring4',
        key_name   => 'vault_key4',
        table      => 't1',
        setup_sql  => "SELECT pg_tde_add_database_key_provider_vault_v2('vault_keyring4',
                '$VAULT_TOKEN',
                '$VAULT_SERVER_URL',
                '$VAULT_SECRET_MOUNT_POINT', NULL)",
        args       => sub {
            my $self = shift;
            return [
                $self->{name},
                $VAULT_TOKEN,
                $VAULT_SERVER_URL,
                $VAULT_SECRET_MOUNT_POINT
            ];
        }
    },
    {
        type       => 'kmip',
        name       => 'kmip_keyring4',
        key_name   => 'kmip_key4',
        table      => 't2',
        setup_sql  => "SELECT pg_tde_add_database_key_provider_kmip('kmip_keyring4',
                '$KMIP_URL',
                $KMIP_PORT,
                '$KMIP_SERVER_CA',
                '$KMIP_SERVER_CLIENT_KEY')",
        args       => sub {
            my $self = shift;
            return [
                $self->{name},
                $KMIP_URL,
                $KMIP_PORT,
                $KMIP_SERVER_CA,
                $KMIP_SERVER_CLIENT_KEY
            ];
            }
    },
    {
        type       => 'file',
        name       => 'file_keyring',
        key_name   => 'file_key1',
        table      => 't3',
        setup_sql  => "SELECT pg_tde_add_database_key_provider_file('file_keyring', '/tmp/file_keyring.per')",
        args       => sub {
            my $self = shift;
            return [
                $self->{name},
                '/tmp/file_keyring.per'
            ];
        }
    }
);


ensure_database_exists_and_accessible($node_primary, $dbname);
$node_primary->safe_psql($dbname, "CREATE EXTENSION pg_tde;");

foreach my $provider (@providers) {
    subtest "Testing $provider->{type} key provider" => sub {
        my @args = $provider->{args}->($provider);
        
        eval {
            $node_primary->safe_psql(
                $dbname,
                $provider->{setup_sql}
            );
            1;
        } or do {
            fail("$provider->{type} key provider creation failed: $@");
            return;
        };
        
        pass("$provider->{type} key provider created successfully");

        # 2. Test key creation
        eval {
            $node_primary->safe_psql($dbname,
                "SELECT pg_tde_set_key_using_database_key_provider(
                    '$provider->{key_name}',
                    '$provider->{name}',
                    'false');");
            1;
        } or do {
            fail("Failed to set key using $provider->{name}: $@");
            return;
        };

        pass("Key set successfully using $provider->{name}");

        # 3. Verify key info
        my $default_key_info = $node_primary->safe_psql($dbname, 
            "SELECT key_name, key_provider_name FROM pg_tde_key_info();");
        like($default_key_info, qr/^$provider->{key_name}\|$provider->{name}$/m, 
            "Database principal key info matches expected");

        # 4. Verify key presence
        my $verify_result = $node_primary->safe_psql($dbname, 
            "SELECT pg_tde_verify_key();");
        is($verify_result, '', 
            "pg_tde_verify_key returns empty string when key is present");

        # 5. Test encrypted table operations
        subtest 'Encrypted table operations' => sub {
            eval {
                $node_primary->safe_psql($dbname, 
                    "CREATE TABLE $provider->{table}(a INT, b varchar) USING tde_heap;");
                $node_primary->safe_psql($dbname,
                    "INSERT INTO $provider->{table} VALUES (100, 'Bob'), (200, 'Foo');");
                $node_primary->safe_psql($dbname,
                    "UPDATE $provider->{table} SET b='Bobvolmer' WHERE a=100;");
                1;
            } or do {
                fail("Table operations failed: $@");
                return;
            };

            pass("Encrypted table created and populated successfully");
            
            is($node_primary->safe_psql($dbname, 
                "SELECT b FROM $provider->{table} WHERE a=100;"), 
                'Bobvolmer', 
                "Update operation verified");
                
            is($node_primary->safe_psql($dbname,
                "SELECT b FROM $provider->{table} WHERE a=200;"),
                'Foo',
                "Second row remains unchanged");
            # Verify encryption status
            my $is_encrypted = $node_primary->safe_psql($dbname,
                "SELECT pg_tde_is_encrypted('$provider->{table}');");
            is($is_encrypted, 't', "Table is properly encrypted");
        };
        # 6. Verify provider appears in listing
        my $local_providers = $node_primary->safe_psql(
            $dbname,
            "SELECT provider_name, provider_type FROM pg_tde_list_all_database_key_providers();"
        );
        like($local_providers, qr/$provider->{name}.*$provider->{type}/i,
            "Provider appears in key providers list") or diag("Actual providers:\n$local_providers")
    };
}

# Restart the server
$node_primary->restart;

foreach my $table (qw/t1 t2 t3/) {
    my $result = $node_primary->safe_psql($dbname, "SELECT COUNT(*) FROM $table");
    chomp($result);
    is($result, '2', "Row count in $table is unchanged after restart. $result");
}

done_testing();

