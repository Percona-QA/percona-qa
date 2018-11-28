#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will do PXB restore check of pquery trials.

BASEDIR=$(grep 'Basedir:' ./pquery-run.log | sed 's|^.*Basedir[: \t]*||;;s/|.*$//' | tr -d '[[:space:]]')
PXB_BASEDIR=$(grep 'PXB Base:' ./pquery-run.log | sed 's|^.*PXB Base[: \t]*||;;s/|.*$//' | tr -d '[[:space:]]')
WORKD_PWD=$PWD

if [ ! -d "${BASEDIR}" ]; then
  echo "Assert! Basedir '${BASEDIR}' does not look to be a directory"
  exit 1
fi

if [ ! -d "${PXB_BASEDIR}" ]; then
  echo "Assert! PXB Basedir '${PXB_BASEDIR}' does not look to be a directory"
  exit 1
fi

while read line ; do
  if [[ -d $WORKD_PWD/$line/xb_full ]]; then 
    rm -rf $WORKD_PWD/$line/data_bkp
    mv $WORKD_PWD/$line/data $WORKD_PWD/$line/data_bkp
    ${PXB_BASEDIR}/bin/xtrabackup --copy-back --target-dir=$WORKD_PWD/$line/xb_full --datadir=$WORKD_PWD/$line/data --lock-ddl > $WORKD_PWD/$line/copy_backup.log 2>&1
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
  else
    echo "TRIAL : $WORKD_PWD/$line backup is not prepared properly" 
  fi 
done < <(grep -B2  'Backup completed' ./pquery-run.log | grep "log stored in" | cut -d'/' -f5)