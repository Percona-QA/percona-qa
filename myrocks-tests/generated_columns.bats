#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Bats tests for generated columns with MyRocks.

# Will be passed from myrocks-testsuite.sh

@test "Adding virtual generated column" {
  #ALTER="alter table generated_columns_test.sbtest1 add column json_test_v json generated always as (json_array(k,c,pad)) virtual"
  conn_string=$(cat cl)
  run ${conn_string} -e "select @@version"
  echo $output
  [ "$status" -eq 0 ]
}
