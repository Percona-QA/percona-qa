#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)

for i in $(ls */*.result | egrep -i "innodb|rocksdb|tokudb|myisam|memory|csv|ndb|merge" | sed 's|/.*||' | sort -u); do 
  if [ -d ${i} ]; then
    cd $i >/dev/null 2>&1
    OUT=$(${SCRIPT_PWD}/diffit.sh)
    cd .. 
    echo "${OUT}" | sed "s|\(.*\)sql: \(.*\)|\2 \[${i}::\1sql\]|"
  else
    echo "Error! ${i} is not a directory!"
  fi
done
