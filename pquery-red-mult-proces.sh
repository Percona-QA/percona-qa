#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# OPTIONAL - If you want to run two or more at the same time, change /dev/shm to another path that reducer can use.
# Make sure that this is an empty subdirectory that can be deleted over and over again!
USE_ALTERNATIVE_DIRECTORY=0  # Set to 1 to enable, 0 for disable
# WARNING! DO NOT USE THE ROOT OF SOME VOLUME OR SOME IMPORTANT DIRECTORY. IT WILL BE WIPED. SET TO AN EMPTY DIRECTORY.
# It does not have to exist yet (Creation will be attempted)
ALT_REDUCER_DIRECTORY=/sda/reducerdir2
# If you use this, reducer will give minor error './reducer<nr>.sh: line 658: [: -lt: unary operator expected' in output
# This is fine/no problem (reducer will continue). It is just due to df -k failing on non-volume directory name
rm -f ./go
sed -i "s|$MULTI_THREADS -ge 51|$MULTI_THREADS -ge 21|" reducer*
if [ ${USE_ALTERNATIVE_DIRECTORY} -eq 1 ]; then
  if [ ! -d ${ALT_REDUCER_DIRECTORY} ]; then
    mkdir ${ALT_REDUCER_DIRECTORY}
    if [ -d ${ALT_REDUCER_DIRECTORY} ]; then
      echo "Created ${ALT_REDUCER_DIRECTORY} which will be used as temporary storage for reducer scripts"
    else
      echo "Assert: ${ALT_REDUCER_DIRECTORY} did not exist, this script tried to created it, but it failed"
      exit 1
    fi
  else
    if [ `ls ${ALT_REDUCER_DIRECTORY}/* 2>/dev/null | wc -l` -gt 0 ]; then
      echo "Assert: ${ALT_REDUCER_DIRECTORY} already exists (see \$ALT_REDUCER_DIRECTORY setting in script) and it contains files..."
      exit 1
    else
      echo "Using pre-existing and currently empty ${ALT_REDUCER_DIRECTORY} as temporary storage for reducer scripts"
    fi
  fi
  sed -i "s|/dev/shm|${ALT_REDUCER_DIRECTORY}|" reducer*
  ls reducer* | sed "s|reducer\([0-9]*\).sh|echo '=== TRIAL #\1'\ntimeout --signal=9 1h ./reducer\1.sh > go_reducer.log\ncat go_reducer.log >> go.log\nworkdir=\`grep \"Workdir:\" go_reducer.log \| awk '{print \$5}'\`\nrm -rf \$workdir|" > go
else
  ls reducer* | sed "s|reducer\([0-9]*\).sh|echo '=== TRIAL #\1'\ntimeout --signal=9 1h ./reducer\1.sh > go_reducer.log\ncat go_reducer.log >> go.log\nworkdir=\`grep \"Workdir:\" go_reducer.log \| awk '{print \$5}'\`\nrm -rf \$workdir|" > go
fi
chmod +x ./go
echo "Start screen session, then execute:  ./go to run all reducers in this directory.Check go.log to analyze the outcome of the various reducer<nr>.sh scripts"
echo "Note: remember to run ~/percona-qa/clean-connects.sh if this is an older pquery-run.sh (with main-new.sql) run"
