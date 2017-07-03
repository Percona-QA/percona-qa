#!/bin/bash
CLIENT_NAME=$1
QR_COUNT=$2
WORKDIR="${PWD}"
MYSQL_USER=root
# Using mysqlslap tool here

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

for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
	MYSQL_SOCK=${i}
  echo "MYSQL_SOCK=${MYSQL_SOCK}"
  ${BASEDIR}/bin/mysqlslap --concurrency=200 --iterations=20 --number-int-cols=2 \
  --number-char-cols=3 --auto-generate-sql \
  --socket=${MYSQL_SOCK} \
  --user=${MYSQL_USER} \
  --auto-generate-sql-unique-query-number=${QR_COUNT} \
  --auto-generate-sql-execute-number=${QR_COUNT} \
  --auto-generate-sql-write-number=${QR_COUNT} \
  --auto-generate-sql-unique-write-number=${QR_COUNT}
done
