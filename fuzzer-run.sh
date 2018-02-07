#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Internal variables - do not modify
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# User variables
BASEDIR=/sda/PS130118-percona-server-5.7.20-19-linux-x86_64-debug  # Warning: running this script will remove ALL data directories in BASEDIR
FUZZERS=192  # Number of sub fuzzers (the total number of fuzzers is one higher as there is a master fuzzer also)

# Auto-created variables (can be changed if needed)
AFL_BIN=${SCRIPT_PWD}/fuzzer/afl-2.52b/afl-fuzz
DICTIONARY=${SCRIPT_PWD}/mysql-dictionary.fuzz
BASE_BIN="$(echo "${BASEDIR}/bin/mysql_embedded")"  # Only use the embedded server, or a setup where client+server are integrated into one binary, compiled/instrumented with afl-gcc or afl-g++ (instrumentation wrappers for gcc/g++)

exit_help(){
  echo "This script expects one startup option: M or S (Master or Slaves) as the first option."
  echo "Also remember to set BASEDIR etc. variables inside the script."
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
elif [ "${1}" == "M" ]; then
  cd /sys/devices/system/cpu
  sudo echo performance | sudo tee cpu*/cpufreq/scaling_governor
fi
cd ${BASEDIR}
if [ "${PWD}" != "${BASEDIR}" ]; then
  echo 'Safety assert: $PWD!=$BASEDIR, please check your BASEDIR path. Tip; avoid double and traling slashe(s).'
  echo "${PWD}!=${BASEDIR}"
fi
if [ ! -d in ]; then
  echo "Please create your in directory with a starting testcase, for example ./in/start.sql"
  echo "Terminating."; exit 1
fi
if [ ! -d out ]; then 
  mkdir out
elif [ "${1}" == "M" ]; then
  echo "(!) Found existing 'out' directory - please ensure that this is what you want; reusing data from a previous run."
  echo "If this is not what you want, please CTRL+C now and delete, rename or move the 'out' directory. Sleeping 13 seconds."
  sleep 13
fi
if [ "${1}" == "M" ]; then
  killall afl-fuzz 2>/dev/null
  rm -Rf data data_TEMPLATE
  ${SCRIPT_PWD}/startup.sh
  ./all_no_cl
  mv ./data ./data_TEMPLATE
fi

# For environment variables see:
# https://github.com/rc0r/afl-fuzz/blob/master/docs/env_variables.txt
# https://groups.google.com/forum/#!searchin/afl-users/AFL_NO_ARITH%7Csort:date/afl-users/1LKXY6u6QDk/KRXna2sPBAAJ

# TERMINAL 1 (master)
if [ "${1}" == "M" ]; then
  rm -Rf ./data0
  cp -r ./data_TEMPLATE ./data0
  echo "Starting master with id fuzzer0..."
  AFL_NO_AFFINITY=1 AFL_SHUFFLE_QUEUE=1 AFL_NO_ARITH=1 AFL_FAST_CAL=1 AFL_NO_CPU_RED=1 ${AFL_BIN} -M fuzzer0 -m 5000 -t 60000 -i in -o out -x ${DICTIONARY} ${BASE_BIN} --server-arg="\"--basedir=${BASEDIR}\"" --server-arg="\"--tmpdir=${BASEDIR}/data0\"" --server-arg="\"--datadir=${BASEDIR}/data0\"" -A --force -e"\"SOURCE @@\"" &
fi

# TERMINAL 2 (after master is up) (subfuzzers)
if [ "${1}" == "S" ]; then
  for FUZZER in $(seq 1 ${FUZZERS}); do
    rm -Rf ./data${FUZZER}
    cp -r ./data_TEMPLATE ./data${FUZZER}
    echo "Starting slave with id fuzzer${FUZZER}..."
    sleep 1; AFL_NO_AFFINITY=1 AFL_SHUFFLE_QUEUE=1 AFL_NO_ARITH=1 AFL_FAST_CAL=1 AFL_NO_CPU_RED=1 ${AFL_BIN} -S fuzzer${FUZZER} -m 5000 -t 60000 -i in -o out -x ${DICTIONARY} ${BASE_BIN} --server-arg="\"--basedir=${BASEDIR}\"" --server-arg="\"--tmpdir=${BASEDIR}/data${FUZZER}\"" --server-arg="\"--datadir=${BASEDIR}/data${FUZZER}\"" -A --force -e"\"SOURCE @@\"" &
  done
  # Cleanup screen in background (can be done manually as well, all processes are in background
  while :; do
    sleep 2
    clear
  done
fi

