#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Checking Audit Plugin installation

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
CONN=$(cat ${BASEDIR}/cl_noprompt)

@test "Checking plugin installation result" {
  result=$($CONN -e "show plugins" | grep -i 'audit_log' | awk '{print $2}')
  echo $output
  [[ $result = "ACTIVE" ]]
}
