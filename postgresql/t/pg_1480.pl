#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgtde;

PGTDE::setup_files_dir(basename($0));

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_tde'");
$node->start;

PGTDE::psql($node, 'postgres', 'CREATE DATABASE testdb;');
PGTDE::psql($node, 'postgres', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');
PGTDE::psql($node, 'testdb', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');

#Create a Global Key Provider
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_add_global_key_provider_file('global_keyring','/tmp/pg_tde_test_pg1480.per');"
);

#Create a Default Principal key using the Global Key Provider
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_set_default_key_using_global_key_provider('principal_key_of_testdb', 'global_keyring');"
);

PGTDE::psql($node, 'testdb',
	'CREATE TABLE t1(a INT PRIMARY KEY, b VARCHAR) USING tde_heap;'
);

PGTDE::psql($node, 'testdb',
	"INSERT INTO t1 VALUES(101, 'James Bond');"
);

#Rotate the Default Principal Key
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_set_default_key_using_global_key_provider('principal_key_of_testdb2', 'global_keyring');"
);

#Query the table
PGTDE::psql($node, 'testdb',
	"SELECT * FROM t1;"
);

PGTDE::append_to_result_file("-- server restart");
$node->restart;

#Query the table
PGTDE::psql($node, 'testdb',
	"SELECT * FROM t1;"
);

PGTDE::psql($node, 'testdb', 'DROP TABLE t1;');
PGTDE::psql($node, 'testdb', 'DROP EXTENSION pg_tde;');
PGTDE::psql($node, 'postgres', 'DROP EXTENSION pg_tde;');

$node->stop;

# Compare the expected and out file
my $compare = PGTDE->compare_results();

is($compare, 0,
	"Compare Files: $PGTDE::expected_filename_with_path and $PGTDE::out_filename_with_path files."
);

done_testing();
