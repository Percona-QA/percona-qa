#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Checking here audit_log_include_databases option

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
CONN=$(cat ${BASEDIR}/cl_noprompt)

@test "running test for audit_log_include_databases='dummy_db'" {
  # First setting to NULL
  $($CONN -e "set global audit_log_include_databases=null")
  # Enabling here
  $($CONN -e "set global audit_log_include_commands='dummy_db'")
  # Creating DB
  $($CONN -e "create database dummy_db")
  # Creating Table
  $($CONN -e "create table dummy_db.dummy_t1(id int not null)")
  # Querying the table
  $($CONN -e "select * from dummy_db.dummy_t1")
  # Checking audit.log file
  sleep 3
  result="$(cat ${BASEDIR}/data/audit.log | grep 'select * from dummy_db.dummy_t1')"
  echo $result | grep "select * from dummy_db.dummy_t1"
}
