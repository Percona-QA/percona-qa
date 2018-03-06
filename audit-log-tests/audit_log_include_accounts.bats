#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Check audit_log_include_accounts option

DIRNAME=$BATS_TEST_DIRNAME
WORKDIR="${PWD}"

BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])
CONN=$(cat ${BASEDIR}/cl_noprompt)

@test "running test for audit_log_include_accounts='root@localhost'" {
  
}
