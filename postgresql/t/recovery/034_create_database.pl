
# Copyright (c) 2023-2024, PostgreSQL Global Development Group

# Test WAL replay for CREATE DATABASE .. STRATEGY WAL_LOG.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('node');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_tde'");
$node->append_conf('postgresql.conf',
	"default_table_access_method = 'tde_heap'");
$node->start;

# Create and enable tde extension
$node->safe_psql('postgres', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
$node->safe_psql('postgres',
	"SELECT pg_tde_add_global_key_provider_file('global_key_provider', '/tmp/global_keyring.file');");
$node->safe_psql('postgres',
	"SELECT pg_tde_set_server_key_using_global_key_provider('global_test_key', 'global_key_provider');");
$node->safe_psql('postgres',
	"SELECT pg_tde_add_database_key_provider_file('local_key_provider', '/tmp/local_keyring.file');");
$node->safe_psql('postgres',
	"SELECT pg_tde_set_key_using_database_key_provider('local_test_key', 'local_key_provider');");

my $WAL_ENCRYPTION = $ENV{WAL_ENCRYPTION} // 'off';

if ($WAL_ENCRYPTION eq 'on'){
	$node->append_conf(
		'postgresql.conf', qq(
		pg_tde.wal_encrypt = on
	));
}

$node->restart;

# This checks that any DDLs run on the template database that modify pg_class
# are persisted after creating a database from it using the WAL_LOG strategy,
# as a direct copy of the template database's pg_class is used in this case.
my $db_template = "template1";
my $db_new = "test_db_1";

# Create table.  It should persist on the template database.
$node->safe_psql($db_template, 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
$node->safe_psql($db_template,
	"SELECT pg_tde_add_database_key_provider_file('local_key_provider', '/tmp/local_keyring.file');");
$node->safe_psql($db_template,
	"SELECT pg_tde_set_key_using_database_key_provider('local_test_key', 'local_key_provider');");
$node->safe_psql("postgres",
	"CREATE DATABASE $db_new STRATEGY WAL_LOG TEMPLATE $db_template;");

$node->safe_psql($db_new,
	"SELECT pg_tde_add_database_key_provider_file('local_key_provider', '/tmp/local_keyring.file');");
$node->safe_psql($db_new,
	"SELECT pg_tde_set_key_using_database_key_provider('local_test_key', 'local_key_provider');");

$node->safe_psql($db_template, "CREATE TABLE tab_db_after_create_1 (a INT);");

# Flush the changes affecting the template database, then replay them.
$node->safe_psql("postgres", "CHECKPOINT;");

$node->stop('immediate');
$node->start;
my $result = $node->safe_psql($db_template,
	"SELECT count(*) FROM pg_class WHERE relname LIKE 'tab_db_%';");
is($result, "1",
	"check that table exists on template after crash, with checkpoint");

# The new database should have no tables.
$result = $node->safe_psql($db_new,
	"SELECT count(*) FROM pg_class WHERE relname LIKE 'tab_db_%';");
is($result, "0",
	"check that there are no tables from template on new database after crash"
);

done_testing();
