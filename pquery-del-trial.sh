#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "" == "$1" ]; then
  echo "This script deletes a given pquery trial completely. Execute this script from within the pquery workdir"
  echo "Example: to delete trial 10 (./10), execute as: ./delete_single_trial.sh 10"
  exit 1
elif [ "`echo $1 | sed 's|[0-9]*||'`" != "" ]; then
  echo "Trial number should be a numeric value and isn't (value passed to this script which is not considered numeric: '$1')"
  exit 1
elif [ ! -d ./$1 ]; then
  echo "This script deletes a given pquery trial completely. Execute this script from within the pquery workdir"
  echo "Error: trial number '$1' was passed as an option to this script. However, no trial $1 directory (./$1) exists! Please check and retry."
  exit 1
fi
TRIAL=$1

rm -Rf ./${TRIAL} > /dev/null 2>&1
rm -f  ./reducer${TRIAL}.sh > /dev/null 2>&1
rm -f  ./${TRIAL}_bundle > /dev/null 2>&1
rm -f  ./${TRIAL}_bundle.tar.gz > /dev/null 2>&1

echo "- pquery trial #${TRIAL} and all related files wiped"
