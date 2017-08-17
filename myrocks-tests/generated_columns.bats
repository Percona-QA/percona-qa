#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Bats tests for generated columns with MyRocks.

# Will be passed from myrocks-testsuite.sh

WORKDIR="${PWD}"
DIRNAME="$BATS_TEST_DIRNAME"
DIRNAME=$(dirname "$0")

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])

function execute_sql() {
  # General function to pass sql statement to mysql client
   ${BASEDIR}/cl -e "$1"
}

@test "Adding virtual generated column" {
  ALTER="alter table generated_columns_test.sbtest1 add column json_test_v json generated always as (json_array(k,c,pad)) virtual"
  execute_sql "$ALTER"
  echo $output
}
