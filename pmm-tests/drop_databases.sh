#!/bin/bash
# This script is using by PMM Stress Test Python code
# Options are passed from there
CLIENT_NAME=$1
MYSQL_SOCK=$2
DATABASE=$3
WORKDIR="${PWD}"
MYSQL_USER=root

if [[ "${CLIENT_NAME}" == "ps" ]]; then
  BASEDIR=$(ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1)
  if [[ -z "$BASEDIR" ]]; then
    echo "*"
  else
    BASEDIR="$WORKDIR/$BASEDIR"
  fi
elif [[ "${CLIENT_NAME}" == "ms" ]]; then
  BASEDIR=$(ls -1td mysql-5.* | grep -v ".tar" | head -n1)
  if [[ -z "$BASEDIR" ]]; then
    echo "*"
  else
    BASEDIR="$WORKDIR/$BASEDIR"
  fi

elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
  BASEDIR=$(ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1)
  if [[ -z "$BASEDIR" ]]; then
    echo "*"
  else
    BASEDIR="$WORKDIR/$BASEDIR"
  fi
fi

if [[ -z "$BASEDIR" ]]; then
  echo "**"
else
  ${BASEDIR}/bin/mysql --user=${MYSQL_USER} --socket=${MYSQL_SOCK} -e "drop database $DATABASE"
fi
