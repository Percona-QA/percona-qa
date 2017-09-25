#!/bin/bash
CLIENT_NAME=$1
INSERT_COUNT=$2
STRING_LENGTH=$3
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

# Function for randomg string
function random-string() {
     head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c ${STRING_LENGTH} ; echo ''
}

str=$(random-string)

if [[ "${CLIENT_NAME}" == "pxc" ]]; then
  MYSQL_SOCK=$(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}' | head -n 1)
  echo "Create database using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_longtext_test"
  echo "Create table using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create table pmm_stress_longtext_test.t_longtext(id int not null, ltext longtext, primary key(id))"
  for num in $(seq 1 1 ${INSERT_COUNT}) ; do
      echo "Inserting long text into table"
	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "insert into pmm_stress_longtext_test.t_longtext(id, ltext) values(${num}, '${str}')"
  done
else
  for i in $(sudo pmm-admin list | grep 'mysql:metrics[ \t].*_NODE-' | awk -F[\(\)] '{print $2}') ; do
  	MYSQL_SOCK=${i}
    echo "Create database using MYSQL_SOCK=${MYSQL_SOCK}"
    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_longtext_test"
    echo "Create table using MYSQL_SOCK=${MYSQL_SOCK}"
    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create table pmm_stress_longtext_test.t_longtext(id int not null, ltext longtext)"
    for num in $(seq 1 1 ${INSERT_COUNT}) ; do
        echo "Inserting long text into table"
  	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "insert into pmm_stress_longtext_test.t_longtext(id, ltext) values(${num}, '${str}')"
    done
  done
fi
