#!/bin/bash
# This script is using by PMM Stress Test Python code
# Options are passed from there
CLIENT_NAME=$1
MYSQL_SOCK=$2
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

echo "echoing basedir"
echo "${BASEDIR}"

if [[ -z "$BASEDIR" ]]; then
  echo "Started fresh run!"
else
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "select schema_name from information_schema.schemata where schema_name not in ('mysql', 'information_schema', 'performance_schema', 'sys')"
fi
