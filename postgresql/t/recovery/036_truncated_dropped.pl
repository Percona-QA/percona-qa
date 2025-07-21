# Copyright (c) 2021-2024, PostgreSQL Global Development Group

# Tests recovery scenarios where the files are shorter than in the common
# cases, e.g. due to replaying WAL records of a relation that was subsequently
# truncated or dropped.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('n1');

$node->init();

# Disable autovacuum to guarantee VACUUM can remove rows / truncate relations
$node->append_conf(
	'postgresql.conf', qq[
wal_level = 'replica'
autovacuum = off
]);
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_tde'");
$node->append_conf('postgresql.conf',
	"default_table_access_method = 'tde_heap'");

$node->start();

# Create and enable tde extension
$node->safe_psql('postgres', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
$node->safe_psql('postgres',
	"SELECT pg_tde_add_global_key_provider_file('global_key_provider', '/tmp/global_keyring.file');");
$node->safe_psql('postgres',
	"SELECT pg_tde_create_key_using_global_key_provider('global_test_key', 'global_key_provider');");
$node->safe_psql('postgres',
	"SELECT pg_tde_set_server_key_using_global_key_provider('global_test_key', 'global_key_provider');");
$node->safe_psql('postgres',
	"SELECT pg_tde_add_database_key_provider_file('local_key_provider', '/tmp/local_keyring.file');");
$node->safe_psql('postgres',
	"SELECT pg_tde_create_key_using_database_key_provider('local_test_key', 'local_key_provider');");
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


# Test: Replay replay of PRUNE records for a pre-existing, then dropped,
# relation

$node->safe_psql(
	'postgres', qq[
CREATE TABLE truncme(i int) WITH (fillfactor = 50);
INSERT INTO truncme SELECT generate_series(1, 1000);
UPDATE truncme SET i = 1;
CHECKPOINT; -- ensure relation exists at start of recovery
VACUUM truncme; -- generate prune records
DROP TABLE truncme;
]);

$node->stop('immediate');

ok($node->start(),
	'replay of PRUNE records for a pre-existing, then dropped, relation');


# Test: Replay of PRUNE records for a newly created, then dropped, relation

$node->safe_psql(
	'postgres', qq[
CREATE TABLE truncme(i int) WITH (fillfactor = 50);
INSERT INTO truncme SELECT generate_series(1, 1000);
UPDATE truncme SET i = 1;
VACUUM truncme; -- generate prune records
DROP TABLE truncme;
]);

$node->stop('immediate');

ok($node->start(),
	'replay of PRUNE records for a newly created, then dropped, relation');


# Test: Replay of PRUNE records affecting truncated block. With FPIs used for
# PRUNE.

$node->safe_psql(
	'postgres', qq[
CREATE TABLE truncme(i int) WITH (fillfactor = 50);
INSERT INTO truncme SELECT generate_series(1, 1000);
UPDATE truncme SET i = 1;
CHECKPOINT; -- generate FPIs
VACUUM truncme; -- generate prune records
TRUNCATE truncme; -- make blocks non-existing
INSERT INTO truncme SELECT generate_series(1, 10);
]);

$node->stop('immediate');

ok($node->start(),
	'replay of PRUNE records affecting truncated block (FPIs)');

is($node->safe_psql('postgres', 'select count(*), sum(i) FROM truncme'),
	'10|55', 'table contents as expected after recovery');
$node->safe_psql('postgres', 'DROP TABLE truncme');


# Test replay of PRUNE records for blocks that are later truncated. Without
# FPIs used for PRUNE.

$node->safe_psql(
	'postgres', qq[
CREATE TABLE truncme(i int) WITH (fillfactor = 50);
INSERT INTO truncme SELECT generate_series(1, 1000);
UPDATE truncme SET i = 1;
VACUUM truncme; -- generate prune records
TRUNCATE truncme; -- make blocks non-existing
INSERT INTO truncme SELECT generate_series(1, 10);
]);

$node->stop('immediate');

ok($node->start(),
	'replay of PRUNE records affecting truncated block (no FPIs)');

is($node->safe_psql('postgres', 'select count(*), sum(i) FROM truncme'),
	'10|55', 'table contents as expected after recovery');
$node->safe_psql('postgres', 'DROP TABLE truncme');


# Test: Replay of partial truncation via VACUUM

$node->safe_psql(
	'postgres', qq[
CREATE TABLE truncme(i int) WITH (fillfactor = 50);
INSERT INTO truncme SELECT generate_series(1, 1000);
UPDATE truncme SET i = i + 1;
-- ensure a mix of pre/post truncation rows
DELETE FROM truncme WHERE i > 500;

VACUUM truncme; -- should truncate relation

-- rows at TIDs that previously existed
INSERT INTO truncme SELECT generate_series(1000, 1010);
]);

$node->stop('immediate');

ok($node->start(), 'replay of partial truncation via VACUUM');

is( $node->safe_psql(
		'postgres', 'select count(*), sum(i), min(i), max(i) FROM truncme'),
	'510|136304|2|1010',
	'table contents as expected after recovery');
$node->safe_psql('postgres', 'DROP TABLE truncme');


done_testing();
