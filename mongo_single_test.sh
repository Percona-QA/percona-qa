#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script executes a single Mongo JS test. In single-use mode, it is executed from within the mongod directory with no options, except TEST_TO_RUN
# (set below) which indicates what test should be run. In automated/wrapper mode (i.e. when called by the wrapper mongo_js_run.sh) one or two variables
# can be passed. The first one ($1) is a working directory which should be used. The second ($2) is the path to mongod. The script will change into this
# directory before continuing with the JS test execution. Note: mongo_js_run.sh will also copy this script into the test directory and modify the
# TEST_TO_RUN parameter for each JS test executed. (Note: If a working directory is passed as $1, it is assumed that this directory already exists)

# Main user/automated script configurable variables
TEST_TO_RUN=./parallel/basic.js            # The actual test to run
PRI_ENGINE=tokuft                          # Primary engine to use for testing (usually tokuft)
SEC_ENGINE=wiredTiger                      # Compare primary engine against this engine (usually mmapv1 or wiredTiger)
TEST_TO_RUN=./noPassthroughWithMongod/index_retry.js

# Semi-configurable user variables. Automated script configurable variables
VERBOSE=1                                  # Leave to 1 unless you know what you are doing (used for script automation/output log vebosity)
WORKDIR=""                                 # Automatically set to /dev/shm if left empty (recommended)

# Internal variables, do not change
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
PRI_ENGINE_NAME=$(echo ${PRI_ENGINE} | tr '[:lower:]' '[:upper:]')
SEC_ENGINE_NAME=$(echo ${SEC_ENGINE} | tr '[:lower:]' '[:upper:]')
PRI_SHORT_ENGINE_NAME=$(echo ${PRI_ENGINE_NAME} | sed 's|V[0-9]\+||')
SEC_SHORT_ENGINE_NAME=$(echo ${SEC_ENGINE_NAME} | sed 's|V[0-9]\+||')

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> /${WORKDIR}/single_test_mongo.log; fi
}

if [ "${1}" == "" ]; then
  TMPFS_SPACE=$(df -BM | grep '/dev/shm' | awk '{print $4}' | head -n1 | sed 's|[^0-9]||')
  if [ "${TMPFS_SPACE}" == "" -o $TMPFS_SPACE -lt 1000 ]; then
    echo "Assert: not sufficient space on /dev/shm (or there were issues accessing /dev/shm). Expected at least 1GB free, but found only ${TMPFS_SPACE}MB."
    exit 1
  fi
  RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
  WORKDIR="/dev/shm/${RANDOMD}"
  mkdir -p ${WORKDIR}
  if [ ! -d ${WORKDIR} ]; then
    echo "Assert: attempted to create ${WORKDIR}, but it does not exist after creation!"
    exit 1
  else
    echoit "Setup work directory ${WORKDIR}..."
  fi
else
  WORKDIR="${1}"
  if [ ! -d ${WORKDIR} ]; then
    echo "Assert: a work directory was passed to this script (${WORKDIR}), however this directory does not exist..."
    exit 1
  else
    if [ ${VERBOSE} -eq 1 ]; then echoit "Using passed work directory ${WORKDIR}..."; fi
  fi
fi

if [ "${2}" != "" ]; then
  if [ ! -d ${2} ]; then
    echoit "Assert: a Mongo directory was passed to this script (${2}), however this directory does not exist..."
    exit 1
  else
    cd ${2}
    if [ ${VERBOSE} -eq 1 ]; then echoit "Changed current directory to ${2}..."; fi
  fi
fi

if [ ${VERBOSE} -eq 1 ]; then echoit "Checking prerequisites..."; fi
if [ ! -r ./mongod -o ! -r ./mongo -o ! -r ./mongos ]; then
  echoit "Assert: required binaries ./mongod, ./mongo and ./mongos not all present in the current directory!"
  echoit "If this is PSMDB RC8+, did you move ./bin/* to the root of the basedir? If not, please do so (and ./jstests/ should be available here also)"
  ps -ef | grep "mongo_js_run" | grep -v grep | awk '{print $2}' | kill -9 >/dev/null 2>&1  # Halting parent script MJR, if running
  exit 1
fi
TEST_TO_RUN=$(echo ${TEST_TO_RUN} | sed 's|^[\.][/]||;s|^jstests[/]||;s|^[\./]\+||')  # If [.][/][jstests][/] is present at the start, remove it
if [ ! -r ${PWD}/jstests/${TEST_TO_RUN} ]; then
  echoit "Assert: test ${TEST_TO_RUN} (i.e. ${PWD}/jstests/${TEST_TO_RUN}) was specified to this script (variable \${TEST_TO_RUN), but the test was not found."
  exit 1
fi

if [ ${VERBOSE} -eq 1 ]; then echoit "Intializing per-engine working directories..."; fi
WORKDIR_PRI="${WORKDIR}/$(echo ${PRI_SHORT_ENGINE_NAME})_RUN_DATA"
mkdir -p ${WORKDIR_PRI}
if [ ! -d ${WORKDIR_PRI} ]; then
  echoit "Assert: this script tried to create the directory ${WORKDIR_PRI}, but the directory does not exist after creation!"
  exit 1
fi
WORKDIR_SEC="${WORKDIR}/$(echo ${SEC_SHORT_ENGINE_NAME})_RUN_DATA"
mkdir -p ${WORKDIR_SEC}
if [ ! -d ${WORKDIR_SEC} ]; then
  echoit "Assert: this script tried to create the directory ${WORKDIR_SEC}, but the directory does not exist after creation!"
  exit 1
fi

PORT1=$[10000 + ( $RANDOM % ( 55000 ) )]  # ~10-65K port range
PORT2=$[10000 + ( $RANDOM % ( 55000 ) )]  # ~10-65K port range

while true ; do
  if [ "$PORT1" != "$PORT2" ]  && [[ ! $(netstat -vatn | grep -0 $PORT1) ]] && [[ ! $(netstat -vatn | grep -0 $PORT2) ]]; then
    break
  else
    PORT1=$[10000 + ( $RANDOM % ( 55000 ) )]  # ~10-65K port range
    PORT2=$[10000 + ( $RANDOM % ( 55000 ) )]  # ~10-65K port range
  fi
done

REPORT_PRI=${WORKDIR}/smoke.py_$(echo ${PRI_SHORT_ENGINE_NAME} | sed 's|V[0-9]\+||').log
REPORT_SEC=${WORKDIR}/smoke.py_$(echo ${SEC_SHORT_ENGINE_NAME} | sed 's|V[0-9]\+||').log
# --with-cleanbb cannot be used (yet): ref smoke.py; cleanbb terminates all mongod instances on the box.
# It is likely also not necessary, as we use per-trial working directories already
DEFAULT_OPTIONS="--mode=files ${PWD}/jstests/${TEST_TO_RUN}"
OPTIONS_PRI="--port=$PORT1 --smoke-db-prefix ${WORKDIR_PRI} --report-file=${REPORT_PRI}.report --storageEngine ${PRI_ENGINE} ${DEFAULT_OPTIONS}"
OPTIONS_SEC="--port=$PORT2 --smoke-db-prefix ${WORKDIR_SEC} --report-file=${REPORT_SEC}.report --storageEngine ${SEC_ENGINE} ${DEFAULT_OPTIONS}"
FILTER='tests succeeded'

if [ ${VERBOSE} -eq 1 ]; then echoit "Terminating all owned mongod instances..."; fi
ps -ef | egrep "mongo" | grep "$(whoami)" | grep "$$" | grep ${WORKDIR} | egrep -v "grep|single|js_run" | awk '{print $2}' | xargs kill -9 2>/dev/null

if [ ${VERBOSE} -eq 1 ]; then echoit "Executing test ${TEST_TO_RUN} against ${PRI_ENGINE}..."; fi
./buildscripts/smoke.py ${OPTIONS_PRI} >> ${REPORT_PRI} 2>&1
RESULT_PRI="$(cat ${REPORT_PRI} | grep "${FILTER}" | head -n1)"
echoit "> ${RESULT_PRI} for ${PRI_ENGINE} on ${TEST_TO_RUN}"

if [ ${VERBOSE} -eq 1 ]; then echoit "Terminating all owned mongod instances..."; fi
ps -ef | egrep "mongo" | grep "$(whoami)" | grep "$$" | grep ${WORKDIR} | egrep -v "grep|single|js_run" | awk '{print $2}' | xargs kill -9 2>/dev/null

if [ ${VERBOSE} -eq 1 ]; then echoit "Executing test ${TEST_TO_RUN} against ${SEC_ENGINE}..."; fi
./buildscripts/smoke.py ${OPTIONS_SEC} >> ${REPORT_SEC} 2>&1
RESULT_SEC="$(cat ${REPORT_SEC} | grep "${FILTER}" | head -n1)"
echoit "> ${RESULT_SEC} for ${SEC_ENGINE} on ${TEST_TO_RUN}"

if [ ${VERBOSE} -eq 1 ]; then echoit "Terminating all owned mongod instances..."; fi
ps -ef | egrep "mongo" | grep "$(whoami)" | grep "$$" | grep ${WORKDIR} | egrep -v "grep|single|js_run" | awk '{print $2}' | xargs kill -9 2>/dev/null

if   [ "${RESULT_PRI}" == "1 tests succeeded" -a "${RESULT_SEC}" == "1 tests succeeded" ]; then
  exit 0
elif [ "${RESULT_PRI}" == "0 tests succeeded" -a "${RESULT_SEC}" == "1 tests succeeded" ]; then
  exit 1
elif [ "${RESULT_PRI}" == "1 tests succeeded" -a "${RESULT_SEC}" == "0 tests succeeded" ]; then
  exit 2
elif [ "${RESULT_PRI}" == "0 tests succeeded" -a "${RESULT_SEC}" == "0 tests succeeded" ]; then
  exit 3
else
  exit 4
fi
