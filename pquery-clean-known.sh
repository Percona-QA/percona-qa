#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script deletes all known found bugs from a pquery work directory. Execute from within the pquery workdir.

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# Current location checks
if [ `ls ./*/pquery_thread-0.sql 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Something is wrong: no pquery trials (with logging - i.e. ./*/pquery_thread-0.sql) were found in this directory"
  exit 1
fi

while read line; do
  STRING="`echo "$line" | sed 's|[ \t]*##.*$||'`"
  if [ "`echo "$STRING" | sed 's|^[ \t]*$||' | grep -v '^[ \t]*#'`" != "" ]; then
    if [ `ls reducer* 2>/dev/null | wc -l` -gt 0 ]; then
      grep -l "${STRING}" reducer* | sed 's/[^0-9]//g' | xargs -I_ $SCRIPT_PWD/pquery-del-trial.sh _
    fi
  fi
  sync; sleep 0.02  # Making sure that next line in file does not trigger same deletions
done < ${SCRIPT_PWD}/known_bugs.strings

if [ -d ./bundles ]; then
  echo "Done! Any trials in ./bundles were not touched."
else
  echo "Done!"
fi
