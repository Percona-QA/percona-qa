#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# BATS tests for mysqldump + MyRocks

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

@test "Running test search rocksdb_enable_bulk_load variable in dump file" {
  result="$(cat ${WORKDIR}/dump1.sql | grep rocksdb_enable | head -n1)"
  echo $output
  [[ $result = "/*!50717 SET @rocksdb_enable_bulk_load = IF (@rocksdb_is_supported, 'SET SESSION rocksdb_bulk_load = 1', 'SET @rocksdb_dummy_bulk_load = 0') */;" ]]
}

@test "Running test search disable_bulk_load variable in dump file" {
  result="$(cat dump1.sql | grep disable_bulk_load | head -n1)"
  echo $output
  [[ $result = "/*!50112 SET @disable_bulk_load = IF (@is_rocksdb_supported, 'SET SESSION rocksdb_bulk_load = @old_rocksdb_bulk_load', 'SET @dummy_rocksdb_bulk_load = 0') */;" ]]
}

@test "Running test search ORDER BY clause in dump file" {
  result="$(cat dump2.sql | grep ORDER | wc -l)"
  echo $output
  [ $result -eq 3 ]
}

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
CONN=$(cat ${BASEDIR}/cl_noprompt)
#echo ${CONN}

@test "Checking salaries1 row count" {
  run ${CONN} -e "select count(*) from employees.salaries1"
  echo $output
  [ "${lines[1]}" -eq 9481 ]
}

@test "Checking salaries2 row count" {
  run ${CONN} -e "select count(*) from employees.salaries2"
  echo $output
  [ "${lines[1]}" -eq 9481 ]
}

@test "Checking salaries3 row count" {
  run ${CONN} -e "select count(*) from employees.salaries3"
  echo $output
  [ "${lines[1]}" -eq 9481 ]
}
