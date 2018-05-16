#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)

if [ "" == "$1" ]; then
  echo "This script expects one parameter: the trial number that this BUNDLE will be created for."
  echo "Please execute this script from within pquery's working/run directory please."
  exit 1
else
  if [ ! -d ./$1 ]; then
    echo "This script expects one parameter: the trial number that this BUNDLE will be created for."
    echo "'$1' was specified as an option to this script, yet ./$1 does not exist? Execute this script from within pquery's working/run directory please."
    exit 1
  else
    TRIALNR=$1
    WORK_PWD=${PWD}
    BUNDLE_DIR=${PWD}/${TRIALNR}_bundle
    TRIAL_DIR=${PWD}/${TRIALNR}
    cd ${TRIAL_DIR}
    if [ "${PWD}" != "${TRIAL_DIR}" ]; then
      echo "The script tried to change directory into ${TRIAL_DIR}, and this should have worked, yet it currently finds itself in ${PWD} which does not match."
      echo "Assert: PWD!=TRIAL_DIR: ${PWD}!=${TRIAL_DIR}"
      exit 1
    fi
  fi
fi

if [ ! -d ${TRIAL_DIR}/data ]; then
  echo "There is no pquery data (${TRIAL_DIR}/data) directory? Terminating."
  exit 1
elif [ ! -r ${TRIAL_DIR}/start ]; then
  echo "There is no start file in the pquery trial directory (${SCRIPT_PWD}/start)? Cannot continue, as this is needed. Terminating."
  exit 1
elif [ ! -r ${SCRIPT_PWD}/ldd_files.sh ]; then
  echo "There is no ldd_files.sh in the script (${SCRIPT_PWD}) directory? Cannot continue, as this is needed. Terminating."
  exit 1
fi

BIN=`grep "mysqld" start | sed 's|mysqld .*|mysqld|;s|/|DUMMY|;s|.*DUMMY|DUMMY|;s|DUMMY|/|'`
echo "mysqld binary: $BIN"

# TODO: expand this script to handle non-core-generating trials (starts being necessary once all core-generating trials have mostly been exhausted).
if [ ! -r ${BIN} ]; then
  # Check if this is a debug build by checking if debug string is present in dirname
  BIN2=`echo "${BIN}-debug"`
  if [ ! -r ${BIN}2 ]; then
    echo "There is no mysqld binary at ${BIN}[-debug]? Did you delete the PS/MS server directory related to this run?"
    echo "Note: the mysqld binary location is/was retrieved from the file ${TRIAL_DIR}/start."
    echo "Cannot continue, as the mysqld binary used for this trial is needed for core analysis. Terminating."
    exit 1
  else
    BIN=${BIN2}
  fi
fi

cd ${TRIAL_DIR}/data
CORE=`ls -1 *core* 2>&1 | head -n1 | grep -v "No such file"`
if [ "" == "${CORE}" ]; then
  echo "Assert: there is no (script readable) [vg]core in ${TRIAL_DIR}/data/ ?"
  exit 1
fi

# Create bundle dir
mkdir ${BUNDLE_DIR}
mkdir ${BUNDLE_DIR}/pquery

# Data directory copy and core move to "root" of bundle dir
cp -R ${TRIAL_DIR}/data ${BUNDLE_DIR}
mv ${BUNDLE_DIR}/data/*core* ${BUNDLE_DIR}

# Error log
cp ${TRIAL_DIR}/log/master.err ${BUNDLE_DIR}

# SQL traces/scripts & pquery log
cp ${TRIAL_DIR}/pquery* ${BUNDLE_DIR}/pquery/

# Binary and ldd files
cp ${BIN} ${BUNDLE_DIR}
cd ${BUNDLE_DIR}
${SCRIPT_PWD}/ldd_files.sh

# Stack traces
TIMEF=`date +%d%m%y-%H%M`
# For debugging purposes, remove ">/dev/null 2>&1" on the next line and observe output
# Note that here the ${CORE} variable represents the file in the original data dir (at ${TRIAL_DIR}/data/core*), yet
# There is a copy of that same coredump file already here in ./${TRIALNR}_bundle. The script could be changed to use this,
# Though it matters little. Also, ldd_files.sh (called above) uses the one in this directory (./${TRIALNR}_bundle) to find
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
  set logging file ${BUNDLE_DIR}/gdb_bug${TRIALNR}_${TIMEF}_FULL.txt
  set logging on
  thread apply all bt full
  set logging off
  set logging file ${BUNDLE_DIR}/gdb_bug${TRIALNR}_${TIMEF}_STD.txt
  set logging on
  thread apply all bt
  set logging off
  quit
EOF

# List all output for review
ls

# Tar up the lot
cd ${WORK_PWD}
tar -zhcf ${TRIALNR}_bundle.tar.gz ./${TRIALNR}_bundle/*

# Report
echo "Done! You can review the directory (./${TRIALNR}_bundle) contents above, and a tar bundle was generated of the same as ./${TRIALNR}_bundle.tar.gz"
