#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgtde;

PGTDE::setup_files_dir(basename($0));

unlink('/tmp/pg_tde_test_pg1401.per');
my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_tde'");
$node->start;

PGTDE::psql($node, 'postgres', 'CREATE EXTENSION IF NOT EXISTS pg_tde;');

PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_add_global_key_provider_file('file-keyring-pg-1401','/tmp/pg_tde_test_pg1401.per');"
);
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_create_key_using_global_key_provider('server-key', 'file-keyring-pg-1401');"
);
PGTDE::psql($node, 'postgres',
	"SELECT pg_tde_set_key_using_global_key_provider('server-key', 'file-keyring-pg-1401');"
);

PGTDE::psql($node, 'postgres',
	'CREATE TABLE t1 (id SERIAL PRIMARY KEY,name VARCHAR(100),t2_id INT) using tde_heap;'
);

PGTDE::psql($node, 'postgres',
	"INSERT INTO t1(name) VALUES ('John'),('Mark');"
);

#Query the table
PGTDE::psql($node, 'postgres',
	"SELECT * FROM t1;"
);

#Change table access method to heap
PGTDE::psql($node, 'postgres',
	"ALTER TABLE t1 SET ACCESS METHOD heap;"
);

#Query the table
PGTDE::psql($node, 'postgres',
	"SELECT * FROM t1;"
);

PGTDE::append_to_result_file("-- Update postgresql.conf, remove pg_tde from shared_preload_libraries");
$node->adjust_conf('postgresql.conf', "shared_preload_libraries', ''");

PGTDE::append_to_result_file("-- server restart");
$node->restart;

#Query the table
PGTDE::psql($node, 'postgres',
	"SELECT * FROM t1;"
);

PGTDE::psql($node, 'postgres', 'DROP TABLE t1;');
PGTDE::psql($node, 'postgres', 'DROP EXTENSION pg_tde;');

$node->stop;

# Compare the expected and out file
my $compare = PGTDE->compare_results();

is($compare, 0,
	"Compare Files: $PGTDE::expected_filename_with_path and $PGTDE::out_filename_with_path files."
);

done_testing();
