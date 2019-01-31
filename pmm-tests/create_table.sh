#!/bin/bash
CLIENT_NAME=$1
TABLE_COUNT=$2
VERSION=$3
WORKDIR="${PWD}"
MYSQL_USER=root


if [[ "${CLIENT_NAME}" == "ps" ]]; then
  BASEDIR=$(ls -1td [Pp]ercona-[Ss]erver-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "ms" ]]; then
  BASEDIR=$(ls -1td mysql-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
  BASEDIR=$(ls -1td Percona-XtraDB-Cluster-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"

elif [[ "${CLIENT_NAME}" == "md" ]]; then
  BASEDIR=$(ls -1td mariadb-${VERSION}* | grep -v ".tar" | head -n1)
  BASEDIR="$WORKDIR/$BASEDIR"
fi

if [[ "${CLIENT_NAME}" == "pxc" ]]; then
  MYSQL_SOCK=$(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}' | head -n 1)
  echo "Creating tables using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test"
  for num in $(seq 1 1 ${TABLE_COUNT}) ; do
	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create table pmm_stress_test.t${num}(id int not null)"
  done
else  
  for i in $(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}') ; do
  	MYSQL_SOCK=${i}
    echo "Creating tables using MYSQL_SOCK=${MYSQL_SOCK}"
    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_test"
    for num in $(seq 1 1 ${TABLE_COUNT}) ; do
  	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create table pmm_stress_test.t${num}(id int not null)"
    done
  done
fi
