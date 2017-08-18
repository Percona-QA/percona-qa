#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# JSON tests for MyRocks table

CONN=$(cat cl)

@test "Adding json column" {
  run ${CONN} -e "alter table generated_columns_test.sbtest1 add column json_test json"
  echo $output
  [ "$status" -eq 0 ]
}
