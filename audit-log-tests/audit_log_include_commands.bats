#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Checking here various SQL commands to be included in audit.log file or not

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
CONN=$(cat ${BASEDIR}/cl_noprompt)

@test "running test for audit_log_include_commands='create_db'" {
  # First setting to NULL
  $($CONN -e "set global audit_log_include_commands=null")
  # Enabling here
  $($CONN -e "set global audit_log_include_commands='create_db'")
  # Creating DB
  $($CONN -e "create database include_commands_test_db1")
  # Checking audit.log file
  sleep 3
  result="$(cat ${BASEDIR}/data/audit.log | grep 'create database include_commands_test_db1')"
  echo $result | grep "include_commands_test_db1"
}
