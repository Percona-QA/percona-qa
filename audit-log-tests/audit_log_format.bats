#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Check audit_log_format to be equal to 'json'

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
CONN=$(cat ${BASEDIR}/cl_noprompt)

@test "running test select @@audit_log_format" {
  result=$($CONN -e "select @@audit_log_format")
  [[ $result=='json' ]]
}
