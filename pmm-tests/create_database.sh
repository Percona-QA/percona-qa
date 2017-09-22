#!/bin/bash
CLIENT_NAME=$1
DB_COUNT=$2
WORKDIR="${PWD}"
MYSQL_USER=root


if [[ "${CLIENT_NAME}" == "ps" ]]; then
  BASEDIR=$(ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "ms" ]]; then
  BASEDIR=$(ls -1td mysql-5.* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
  BASEDIR=$(ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"
fi

if [[ "${CLIENT_NAME}" == "pxc" ]]; then
  MYSQL_SOCK=$(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}' | head -n 1)
  echo "Creating databases using MYSQL_SOCK=${MYSQL_SOCK}"
  for num in $(seq 1 1 ${DB_COUNT}) ; do
	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test_${num}"
  done
else
  for i in $(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}') ; do
  	MYSQL_SOCK=${i}
    echo "Creating databases using MYSQL_SOCK=${MYSQL_SOCK}"
    for num in $(seq 1 1 ${DB_COUNT}) ; do
  	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test_${num}"
    done
  done
fi
