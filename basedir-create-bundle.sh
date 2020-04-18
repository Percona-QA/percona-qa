#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
WORK_PWD=$PWD

if [ "" == "$1" ]; then
  echo "This script expects one parameter: the bug number that this BUNDLE will be created for."
  echo "Please execute this script from within a mysqld build directory (i.e. it contains ./bin, ./data etc.)"
  exit 1
elif [ ! -d ${WORK_PWD}/data ]; then
  echo "There is no ./data (${WORK_PWD}/data) directory? Terminating."
  exit 1
elif [ ! -d ${WORK_PWD}/bin ]; then
  echo "There is no ./bin (${WORK_PWD}/bin) directory? Terminating."
  exit 1
elif [ ! -r ${SCRIPT_PWD}/ldd_files.sh ]; then
  echo "There is no ldd_files.sh in the script (${SCRIPT_PWD}) directory? Terminating."
  exit 1
else
  BUGNR=$1
fi

cd $WORK_PWD/data
CORE=`ls -1 *core* 2>&1 | head -n1 | grep -v "No such file"`
if [ "" == "${CORE}" ]; then
  echo "Assert: there is no (script readable) [vg]core in ${WORK_PWD}/data/ ?"
  exit 1
fi
cd $WORK_PWD

if [ -r ${WORK_PWD}/bin/mysqld ]; then
  BIN=${WORK_PWD}/bin/mysqld
else
  # Check if this is a debug build by checking if debug string is present in dirname
  if [[ ${WORK_PWD} = *debug* ]]; then
    if [ -r ${WORK_PWD}/bin/mysqld-debug ]; then
      BIN=${WORK_PWD}/bin/mysqld-debug
    else
      echo "Assert: there is no (script readable) mysqld binary at ${WORK_PWD}/bin/mysqld[-debug] ?"
      exit 1
    fi
  else
    echo "Assert: there is no (script readable) mysqld binary at ${WORK_PWD}/bin/mysqld ?"
    exit 1
  fi
fi

TIMEF=`date +%d%m%y-%H%M`

mkdir bug${BUGNR}
cp -R data bug${BUGNR}/
cp $BIN bug${BUGNR}/
cp log/master.err bug${BUGNR}/
cd bug${BUGNR}/
mv ./data/*core* .
${SCRIPT_PWD}/ldd_files.sh

# For debugging purposes, remove ">/dev/null 2>&1" on the next line and observe output
# Note that here the $CORE variable represents the file in the original data dir (at ${WORK_PWD}/data/*core*), yet
# There is a copy of that same coredump file already here in ./bug${BUGNR}. The script could be changed to use this,
# Though it matters little. Also, ldd_files.sh (called above) uses the one in this directory (./bug${BUGNR}) to find
# it's lib64 dependency files, so it's a bit of a mix atm. Works well, and no issues foreseeable, but could be changed.
gdb ${BIN} ${CORE} >/dev/null 2>&1 <<EOF
  # Avoids libary loading issues / more manual work, see bash$ info "(gdb)Auto-loading safe path"
  set auto-load safe-path /
  # See http://sourceware.org/gdb/onlinedocs/gdb/Threads.html - this avoids the following issue:
  # "warning: unable to find libthread_db matching inferior's threadlibrary, thread debugging will not be available"
  set libthread-db-search-path /usr/lib/
  set trace-commands on
  set pagination off
  set print pretty on
  set print array on
  set print array-indexes on
  set print elements 4096
  set logging file gdb_bug${BUGNR}_${TIMEF}_FULL.txt
  set logging on
  thread apply all bt full
  set logging off
  set logging file gdb_bug${BUGNR}_${TIMEF}_STD.txt
  set logging on
  thread apply all bt
  set logging off
  quit
EOF

# List all output for review
ls

# Tar up the lot
cd ${WORK_PWD}
tar -zhcf bug-${BUGNR}.tar.gz ./bug${BUGNR}/*

# Report
echo "Done! You can review the directory (./bug${BUGNR}) contents above, and a tar bundle was generated of the same as ./bug-${BUGNR}.tar.gz"
