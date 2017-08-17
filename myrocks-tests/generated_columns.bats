#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Bats tests for generated columns with MyRocks.

# Will be passed from myrocks-testsuite.sh

CONN=$(cat cl)

@test "Adding virtual generated json type column" {
  #ALTER="alter table generated_columns_test.sbtest1 add column json_test_v json generated always as (json_array(k,c,pad)) virtual"
  run ${CONN} -e "alter table generated_columns_test.sbtest1 add column json_test_v json generated always as (json_array(k,c,pad)) virtual"
  echo $output
  [ "${lines[0]}" = "ERROR 3106 (HY000) at line 1: 'Specified storage engine' is not supported for generated columns." ]
}

@test "Adding stored generated json type column" {
  run ${CONN} -e "alter table generated_columns_test.sbtest1 add column json_test_v json generated always as (json_array(k,c,pad)) stored"
  echo $output
  [ "${lines[0]}" = "ERROR 3106 (HY000) at line 1: 'Specified storage engine' is not supported for generated columns." ]
}

@test "Adding stored generated varchar type column" {
  run ${CONN} -e "alter table generated_columns_test.sbtest1 add column json_test_index varchar(255) generated always as (json_array(k,c,pad)) stored"
  echo $output
  [ "${lines[0]}" = "ERROR 3106 (HY000) at line 1: 'Specified storage engine' is not supported for generated columns." ]
}
