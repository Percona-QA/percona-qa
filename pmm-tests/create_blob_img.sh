#!/bin/bash
CLIENT_NAME=$1
INSERT_COUNT=$2
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

# Allocating test image here
fallocate -l 100M t_blob.img

#for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
for i in $(sudo pmm-admin list | grep 'mysql:metrics[ \t]*PS_NODE' | awk -F[\(\)] '{print $2}') ;  do
	MYSQL_SOCK=${i}
  echo "Create database using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create database pmm_stress_blob_test"
  echo "Create table using MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "create table pmm_stress_blob_test.t_blob(id int not null, img longblob)"
  for num in $(seq 1 1 ${INSERT_COUNT}) ; do
      echo "Inserting image into table"
	    ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "insert into pmm_stress_blob_test.t_blob(id, img) values(1, LOAD_FILE('${WORKDIR}/t_blob.img'))"
  done
done
