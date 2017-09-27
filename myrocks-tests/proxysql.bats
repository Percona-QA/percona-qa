#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

# Testing servers configured with ProxySQL

WORKDIR="${PWD}"
BASEDIR=$(ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1)

CONN1=$(cat ${WORKDIR}/${BASEDIR}/cl_ps1)
CONN2=$(cat ${WORKDIR}/${BASEDIR}/cl_ps2)
CONN3=$(cat ${WORKDIR}/${BASEDIR}/cl_ps3)

@test "Running select on PS1" {
  result="$(${CONN1} -e 'select pad from proxysql_test_db.sbtest1')"
  echo $output
  [[ $result = "We are the warriors of true!" ]]
}

# @test "Running select on PS2" {
#   result="$(${CONN2} -e 'select pad from proxysql_test_db.sbtest1')"
#   echo $output
#   [[ $result = "We are the warriors of true!" ]]
# }
#
# @test "Running select on PS3" {
#   result="$(${CONN3} -e 'select pad from proxysql_test_db.sbtest1')"
#   echo $output
#   [[ $result = "We are the warriors of true!" ]]
# }
