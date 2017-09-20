#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# BATS tests for mysqldump + MyRocks

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

@test "Running test search rocksdb_enable_bulk_load variable inside dump" {
  result="$(cat ${WORKDIR}/dump1.sql | grep rocksdb_enable | head -n1)"
  echo $output
  [[ $result = "/*!50717 SET @rocksdb_enable_bulk_load = IF (@rocksdb_is_supported, 'SET SESSION rocksdb_bulk_load = 1', 'SET @rocksdb_dummy_bulk_load = 0') */;" ]]
}
