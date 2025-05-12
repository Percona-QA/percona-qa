#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use File::Basename;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use lib 't';
use pgtde;
use tde_helper;
use Time::HiRes qw(time sleep);
use IPC::Run qw(run);
use POSIX ":sys_wait_h";
use File::Temp qw(tempfile);
use POSIX qw(_exit);
use File::Path 'make_path';

PGTDE::setup_files_dir(basename($0));

my $TOTAL_PARTITIONS = 5;
my $DB_NAME= "test_db";
my $PARTITION_PARENT = "partitioned_table";
my $TABLESPACE_NAME = "custom_tablespace";
my $TABLESPACE_LOC = "/tmp/$TABLESPACE_NAME";

# Initialize primary node
my $node_primary = PostgreSQL::Test::Cluster->new('primary');
$node_primary->init;

enable_pg_tde_in_conf($node_primary);
set_default_table_am_tde_heap($node_primary);
$node_primary->start;

# Create a new database if not exists
ensure_database_exists_and_accessible($node_primary, $DB_NAME);

# Setup pg_tde encryption on the primary node
setup_encryption($node_primary, $DB_NAME);

# Create tablespace
my $ts_location = $node_primary->basedir . '/custom_tablespace';
make_path($ts_location) unless -d $ts_location;

$node_primary->safe_psql($DB_NAME, "DROP TABLESPACE IF EXISTS custom_tablespace");
$node_primary->safe_psql($DB_NAME, "CREATE TABLESPACE custom_tablespace LOCATION '$ts_location'");

$node_primary->safe_psql($DB_NAME, qq{
    CREATE TABLE IF NOT EXISTS $PARTITION_PARENT (
        id SERIAL,
        data TEXT,
        created_at DATE NOT NULL,
        PRIMARY KEY (id, created_at)
    ) PARTITION BY RANGE (created_at) USING tde_heap;
});

# Create partitions
for my $i (1 .. $TOTAL_PARTITIONS) {
    my $start_month = sprintf("%02d", $i);
    my $end_month   = sprintf("%02d", $i + 1);
    my $partition_name = "${PARTITION_PARENT}_p$i";

    $node_primary->safe_psql($DB_NAME, qq{
        CREATE TABLE IF NOT EXISTS $partition_name
        PARTITION OF $PARTITION_PARENT
        FOR VALUES FROM ('2025-$start_month-01') TO ('2025-$end_month-01') USING tde_heap;
    });

    diag("Created partition: $partition_name");
}

# Insert 1000 random rows
for my $i (1 .. 1000) {
    my $random_month = sprintf("%02d", int(rand($TOTAL_PARTITIONS)) + 1);
    my $random_day   = sprintf("%02d", int(rand(28)) + 1);
    my $date         = "2025-$random_month-$random_day";
    my $data         = "Sample data $i";

    $node_primary->safe_psql($DB_NAME, qq{
        INSERT INTO $PARTITION_PARENT (data, created_at)
        VALUES ('$data', '$date');
    });
}

pass("Partitioned insert test completed");
    
# Count rows before migration
my $before_count = $node_primary->safe_psql($DB_NAME,
    "SELECT COUNT(*) FROM $PARTITION_PARENT");
diag("Count of rows before moving to external tablespace: $before_count");

# Move table to external tablespace
diag("Moving $PARTITION_PARENT to tablespace $TABLESPACE_NAME");
$node_primary->safe_psql($DB_NAME,
    "ALTER TABLE $PARTITION_PARENT SET TABLESPACE $TABLESPACE_NAME");

# Count rows after moving
my $after_count = $node_primary->safe_psql($DB_NAME,
    "SELECT COUNT(*) FROM $PARTITION_PARENT");
diag("Count of rows after migration: $after_count");

is($after_count, $before_count, "Row count after move to $TABLESPACE_NAME is correct");

# Move table back to pg_default
diag("Moving $PARTITION_PARENT back to pg_default");
$node_primary->safe_psql($DB_NAME,
    "ALTER TABLE $PARTITION_PARENT SET TABLESPACE pg_default");

# Final count
my $final_count = $node_primary->safe_psql($DB_NAME,
    "SELECT COUNT(*) FROM $PARTITION_PARENT");
diag("Final row count after moving back: $final_count");

is($final_count, $before_count, "Row count after move back to pg_default is correct");

done_testing();

