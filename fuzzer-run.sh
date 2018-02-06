#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Internal variables - do not modify
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# User variables
BASEDIR=/sda/PS130118-percona-server-5.7.20-19-linux-x86_64-debug  # Warning: running this script will remove ALL data directories in BASEDIR
FUZZERS=64  # Number of sub fuzzers (the total number of fuzzers is one higher as there is a master fuzzer also)

# Auto-created variables (can be changed if needed)
AFL_BIN=${SCRIPT_PWD}/fuzzer/afl-2.52b/afl-fuzz
DICTIONARY=${SCRIPT_PWD}/mysql-dictionary.fuzz
BASE_BIN="$(echo "${BASEDIR}/bin/mysql_embedded")"  # Only use the embedded server, or a setup where client+server are integrated into one binary, compiled/instrumented with afl-gcc or afl-g++ (instrumentation wrappers for gcc/g++)

exit_help(){
  echo "This script expects one startup option: M or S (Master or Slaves) as the first option. Also remember to set BASEDIR etc. variables inside the script."
  echo "Note that it is recommended to run M (Master) in a seperate terminal from S (Slaves), allowing better output analysis."
  echo "Warning: running this script will remove ALL data directories in BASEDIR!"
  echo "Terminating."; exit 1
}
# Setup
if [ ! -r ${BASE_BIN} ]; then
  echo "${BASE_BIN} not present! Please compile a server with the embedded server included"
  echo "Terminating."; exit 1
fi
if [ "${1}" == "" ]; then
  exit_help
elif [ "${1}" != "M" -a "${1}" != "S" ]; then
  exit_help
fi
cd ${BASEDIR}
if [ ! -d in ]; then
  echo "Please create your in directory with a starting testcase, for example ./in/start.sql"
  echo "Terminating."; exit 1
fi
if [ ! -d out ]; then 
  mkdir out
else
  echo "Found existing 'out' directory - please ensure that this is what you want; re-use data from a previous run. Sleeping 5 seconds"
  sleep 5
fi
killall afl-fuzz
rm -Rf afldata* data_TEMPLATE data fuzzer*
${SCRIPT_PWD}/startup.sh
./all
mv data data_TEMPLATE

# TERMINAL 1 (master)
if [ "${1}" == "M" ]; then
  cp -r data_TEMPLATE data0
  mkdir fuzzer0
  echo "Starting master with id fuzzer0..."
  AFL_NO_AFFINITY=1 ${AFL_BIN} -M fuzzer0 -m 4000 -t 30000 -i in -o out -x ${DICTIONARY} ${BASE_BIN} --server-arg="\"--basedir=${BASEDIR}\"" --server-arg="\"--tmpdir=${BASEDIR}/data0\"" --server-arg="\"--datadir=${BASEDIR}/data0\"" -A --force -e"\"SOURCE @@\"" &
fi

# TERMINAL 2 (after master is up) (subfuzzers)
if [ "${1}" == "S" ]; then
  for FUZZER in $(seq 1 ${FUZZERS}); do
    cp -r data_TEMPLATE data${FUZZER}
    mkdir fuzzer${FUZZER}
    echo "Starting slave with id fuzzer${FUZZER}..."
    sleep 1; AFL_NO_AFFINITY=1 ${AFL_BIN} -S fuzzer${FUZZER} -m 4000 -t 30000 -i in -o out -x ${DICTIONARY} ${BASE_BIN} --server-arg="\"--basedir=${BASEDIR}\"" --server-arg="\"--tmpdir=${BASEDIR}/data${FUZZER}\"" --server-arg="\"--datadir=${BASEDIR}/data${FUZZER}\"" -A --force -e"\"SOURCE @@\"" &
  done
  # Cleanup screen in background (can be done manually as well, all processes are in background
  clear; sleep 2; clear
  $(sleep 60; echo "clear)" &
  $(sleep 120; echo "clear") &
  $(sleep 180; echo "clear") &
  $(sleep 240; echo "clear") &
  $(sleep 300; echo "clear") &
fi

