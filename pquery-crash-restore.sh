#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will check the crash recovery of pquery trial.

BASEDIR=$(grep 'Basedir:' ./pquery-run.log | sed 's|^.*Basedir[: \t]*||;;s/|.*$//' | tr -d '[[:space:]]')
WORKD_PWD=$PWD

if [ ! -d "${BASEDIR}" ]; then
  echo "Assert! Basedir '${BASEDIR}' does not look to be a directory"
  exit 1
fi

while read line ; do
  $line/start_recovery 
  for X in $(seq 0 60); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$WORKD_PWD/$line/socket.sock ping > /dev/null 2>&1; then
      echo "($line) Percona Server restore is successful"
      sleep 2
      ${BASEDIR}/bin/mysqladmin -uroot -S$WORKD_PWD/$line/socket.sock shutdown > /dev/null 2>&1
      break
    fi
    if [ $X -eq 60 ]; then
      echo "($line) Percona Server startup failed.."
      grep "ERROR" $WORKD_PWD/$line/log/master.err
    fi
  done
done < <(grep -B2  'killed for crash testing' ./pquery-run.log | grep "log stored in" | cut -d'/' -f5)

