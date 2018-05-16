#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# To get a better idea on the working of this script, see the header comments in mongo_single_test.sh. Basically mongo_js_run.sh is an intelligent wrapper
# around mongo_single_test.sh. It analyzes output of mongo_single_test.sh &  reports on the same. It also stores interesting results to a ${RESULTSDIR} dir.

# User configurable variables
MONGODIR="/sdc/percona-server-mongodb-3.0.7-1.0"    # Where mongo/mongod lives (with ./mongod and ./jstests both present!)
RESULTS_DIR="/sdc"                         # Where failures/bugs are stored
JS_LIST="/sdc/js_tests_to_run.txt"         # Temporary file of JS tests (created by this script)
THREADS=10                                 # Number of threads that should run
TIMEOUT=$[ 60 * 30 ]                       # Timeout, in seconds, per test (currently 30 min)
FILES_ULIMIT=100000                        # Ulimit -n value which script will attempt to set (TokuFT needs many file descriptors)
PRI_ENGINE=PerconaFT                       # Primary engine to use for testing (usually tokuft)
#SEC_ENGINE=wiredTiger                      # Compare primary engine against this engine (usually mmapv1 or wiredTiger)
SEC_ENGINE=MMAPv1

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)
TEST_IN_PROGRESS=0
WORKDIR=""
RESULTSDIR=""
MUTEX1=0;MUTEX2=0
SEGREGATED=0
CTRL_C_PRESSED=0

# Trap ctrl-c
trap ctrl-c SIGINT

ctrl-c(){
  echoit "CTRL+c Was pressed. Results directory: ${RESULTSDIR}" CTRLC
  echoit "Attempting to terminate running processes..." CTRLC
  touch ${RESULTSDIR}/ctrl_c_was_pressed_during_this_run
  kill_pids
  sleep 1 # Allows background termination & screen output to finish
  echoit "Terminating mongo-js-run.sh with exit code 2..." CTRLC
  exit 2
}

kill_pids(){
  KILL_PIDS=`ps -ef | grep mongo | grep -v grep | grep -v 'mongo_js_run' | egrep "${WORKDIR}|${RESULTSDIR}" | awk '{print $2}' | tr '\n' ' '`
  if [ "${KILL_PIDS}" != "" ]; then
    echoit "Terminating the following PID's: ${KILL_PIDS}"
    kill -9 ${KILL_PIDS} >/dev/null 2>&1
  fi
}

echoit(){
  if [ "$2" == "CTRLC" ]; then  # CTRL+C was pressed, format output witout echoit_counters
    echo "[$(date +'%T')] [CTRL+C] $1"
    if [ "${RESULTSDIR}" != "" ]; then echo "[$(date +'%T')] [CTRL+C] $1" >> ${RESULTSDIR}/mongo_js_run.log; fi
  elif [ ! -r ${RESULTSDIR}/ctrl_c_was_pressed_during_this_run ]; then  # Standard output (CTRL+C was not pressed [yet])
    echo "[$(date +'%T')]$(echoit_counters)$1"
    if [ "${RESULTSDIR}" != "" ]; then echo "[$(date +'%T')]$(echoit_counters)$1" >> ${RESULTSDIR}/mongo_js_run.log; fi
  fi
}

echoit_counters(){
  if [ ${TEST_IN_PROGRESS} -eq 0 -o "${TEST_IN_PROGRESS}" == "" ]; then
    echo -n " "
  else
    if [ -r ${RESULTSDIR}/saved.lock ]; then
      SAVED=$(cat ${RESULTSDIR}/saved.lock | head -n1)
    else
      SAVED=0
      echo "Warning: Debug assertion: ${RESULTSDIR}/saved.lock did not exist when accessed from echoit_counters(), this should not happen."
    fi
    echo -n " [${TEST_IN_PROGRESS}/${TEST_COUNT}] [${SAVED}] "
  fi
}

loop(){  # $1 to this function is the JS TEST_TO_RUN
  RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(........\).*/\1/')  # Random number generator (8 digits)
  WORKDIR="/dev/shm/${RANDOMD}"

  echoit "Setting up trial working directory ${WORKDIR}..."
  mkdir -p ${WORKDIR}
  if [ ! -d ${WORKDIR} ]; then
    echo "Assert: attempted to create ${WORKDIR}, but it does not exist after creation!"
    exit 1
  fi

  cp ${SCRIPT_PWD}/mongo_single_test.sh ${WORKDIR}/mongo_single_test.sh
  sed -i "s|^[ \t]*TEST_TO_RUN=.*|TEST_TO_RUN=${1}|;s|^[ \t]*DEBUG=.*|DEBUG=0|" ${WORKDIR}/mongo_single_test.sh
  sed -i "s|^[ \t]*PRI_ENGINE=.*|PRI_ENGINE=${PRI_ENGINE}|;s|^[ \t]*SEC_ENGINE=.*|SEC_ENGINE=${SEC_ENGINE}|" ${WORKDIR}/mongo_single_test.sh
  timeout --signal=9 ${TIMEOUT}s ${WORKDIR}/mongo_single_test.sh ${WORKDIR} ${MONGODIR}
  RESULT=$?  # 0: Both engines succeeded | 1: PRI engine failed only | 2: SEC engine failed only | 3: Both engines failed | 4: Unknown issue (should not happen) | 137: timeout

  if [ ${RESULT} -eq 0 ]; then
    echoit "Both engines succeeded on ${1}, deleting test results..."
    rm -Rf ${WORKDIR}
  elif [ ${RESULT} -eq 1 ]; then
    update_saved_counter
    echoit "Primary engine (TokuMX[se]) failed on ${1}, saving details in ${RESULTSDIR}/${RANDOMD}..."
    mv ${WORKDIR} ${RESULTSDIR}
    if [ ! -d ${RESULTSDIR}/${RANDOMD} ]; then
      echo "Assert: attempted to move ${WORKDIR} to ${RESULTSDIR}, but this seems to have failed. Out of disk space maybe? Terminating run..."
      exit 1
    fi
  elif [ ${RESULT} -eq 2 ]; then
    echoit "Only secondary engine failed on ${1}, ignoring & deleting test results..."
    rm -Rf ${WORKDIR}
  elif [ ${RESULT} -eq 3 ]; then
    #Once tokuft-only failures are cleared, we can start looking into test failures where both engines fail. Ftm, we are ignoring/deleting them
    #update_saved_counter
    #echoit "Both engines failed on ${1}, saving details in ${RESULTSDIR}/${RANDOMD}..."
    #mv ${WORKDIR} ${RESULTSDIR}
    #if [ ! -d ${RESULTSDIR}/${RANDOMD} ]; then
    #  echo "Assert: attempted to move ${WORKDIR} to ${RESULTSDIR}, but this seems to have failed. Out of disk space maybe? Terminating run..."
    #  exit 1
    #fi
    echoit "Both engines failed on ${1}, ignoring & deleting test results..."
    rm -Rf ${WORKDIR}
  elif [ ${RESULT} -eq 137 ]; then
    echoit "Test ${1} was interrupted as it went over the ${TIMEOUT}s timeout, saving details in ${RESULTSDIR}/${RANDOMD}..."
    update_saved_counter
    mv ${WORKDIR} ${RESULTSDIR}
    if [ ! -d ${RESULTSDIR}/${RANDOMD} ]; then
      echo "Assert: attempted to move ${WORKDIR} to ${RESULTSDIR}, but this seems to have failed. Out of disk space maybe? Terminating run..."
      exit 1
    fi
    mv ${RESULTSDIR}/${RANDOMD} ${RESULTSDIR}/${RANDOMD}_TIMEOUT
    if [ ! -d ${RESULTSDIR}/${RANDOMD}_TIMEOUT ]; then
      echo "Assert: attempted to move/rename ${RESULTSDIR}/${RANDOMD} to ${RESULTSDIR}/${RANDOMD}_TIMEOUT, but this seems to have failed. Terminating run..."
      exit 1
    fi
    echo "Trial ${1} was interrupted as it went over the ${TIMEOUT}s timeout!" > ${RESULTSDIR}_TIMEOUT/${RANDOMD}/this_trial_was_interrupted.txt
  elif [ ${RESULT} -ge 4 -o ${RESULT} -lt 0 ]; then
    echoit "Assert: mongo_single_test.sh returned exit code ${RESULT} for test ${1}, this should not happen! Terminating run..."
    exit 1
  fi
}

update_saved_counter(){  # Use a MUTEX to ensure that two or more threads do not update the failure counter ($SAVED) at the same time
  if [ ${MUTEX2} -eq 0 ]; then
    MUTEX2=1
  else
    while [ ${MUTEX2} -ne 0 ]; do
      sleep 2
    done
    MUTEX2=1
  fi
  SAVED=$(cat ${RESULTSDIR}/saved.lock | head -n1)
  SAVED=$[ ${SAVED} + 1 ]
  echo ${SAVED} > ${RESULTSDIR}/saved.lock
  MUTEX2=0
}

start_thread(){  # Use a MUTEX to ensure that two or more threads do not update the test counter / access the tests list file at the same time
  if [ ${MUTEX1} -eq 0 ]; then
    MUTEX1=1
  else
    while [ ${MUTEX1} -ne 0 ]; do
      sleep 2
    done
    MUTEX1=1
  fi
  TEST_INPUT_FILE_TO_USE=
  if [ ${SEGREGATED} -eq 0 ]; then
    TEST_INPUT_FILE_TO_USE=${RESULTSDIR}/jstests.list
  elif [ ${SEGREGATED} -eq 1 ]; then
    TEST_INPUT_FILE_TO_USE=${RESULTSDIR}/jstests_single.list
  else
    echoit "Assert: \${SEGREGATED}!=0 && \${SEGREGATED}!=1"
    exit 1
  fi
  TEST_IN_PROGRESS=$[ ${TEST_IN_PROGRESS} + 1 ]
  TEST_TO_RUN="$(head -n${TEST_IN_PROGRESS} ${TEST_INPUT_FILE_TO_USE} | tail -n1)"  # Path inside jstests + test name. For example, TEST_TO_RUN=core/system_profile.js
  loop ${TEST_TO_RUN} &
  MUTEX1=0
}

RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
RESULTSDIR=$(echo "/${RESULTS_DIR}/${RANDOMD}" | sed 's|//|/|g')
mkdir -p ${RESULTSDIR}
echo "0" > ${RESULTSDIR}/saved.lock  # ${SAVED} count will be read, and updated into, from/to this file
if [ ! -d ${WORKDIR} ]; then
  echo "Assert: attempted to create ${RESULTSDIR}, but it does not exist after creation!"
  exit 1
else
  if [ ! -r ${RESULTSDIR}/saved.lock ]; then
    echo "Assert: attempted to create ${RESULTSDIR}/saved.lock, but it does not exist or cannot be read (privileges issue?) after creation!"
    exit 1
  else
    echoit "MJR (mongo-js-run.sh) v1.03 | Threads: ${THREADS} | Per-test timeout: ${TIMEOUT}s | Results directory: ${RESULTSDIR}"
    echoit "Mongo base directory: ${MONGODIR} | Primary engine: ${PRI_ENGINE} | Secondary engine: ${SEC_ENGINE}"
    echoit "Setup main results directory ${RESULTSDIR}..."
  fi
fi

echoit "Making a copy of ${WORKDIR}/mongo_js_run.sh to ${RESULTSDIR} for later reference..."
cp ${SCRIPT_PWD}/mongo_js_run.sh ${RESULTSDIR}

echoit "Terminating all owned mongod instances..."
${SCRIPT_PWD}/mongo_kill_procs_safe.sh

echoit "Attempting to increase/set ulimit -n to ${FILES_ULIMIT}..."
ulimit -n ${FILES_ULIMIT} 2>/dev/null
if [ "$(ulimit -n)" != "${FILES_ULIMIT}" ]; then
  echoit "Assert: After attempting to set ulimit -n to ${FILES_ULIMIT}, the ulimit -n setting is [still] $(ulimit -n) instead!"
  echoit "Using sudo, edit /etc/security/limits.conf and add the following line to the end of the file:"
  echoit "* hard nofile $(echo $[ ${FILES_ULIMIT} + 1000 ])"
  exit 1
fi

echoit "Compiling list of all JS tests to be executed..."
if [ ! -d ${MONGODIR}/jstests ]; then
  echoit "Assert: Before changing directories into ${MONGODIR}/jstests, this script checked the existence of this directory, and failed!"
  exit 1
else
  rm -f ${RESULTSDIR}/jstests.list; touch ${RESULTSDIR}/jstests.list
  cd ${MONGODIR}/jstests
  find . | grep "\.js$" > ${RESULTSDIR}/jstests.list
  TEST_COUNT=$(cat ${RESULTSDIR}/jstests.list 2>/dev/null | wc -l)
  if [ "${TEST_COUNT}" == "" ]; then TEST_COUNT=0; fi
  if [ ${TEST_COUNT} -lt 1000 ]; then  # Currently there are 1727 tests!
    echoit "Assert: The number of all JS tests (${TEST_COUNT}) is too small, check for build issues & verify contents of ${RESULTSDIR}/jstests.list!"
    exit 1
  else
    echoit "${TEST_COUNT} JS tests discovered..."
  fi
fi

echoit "Segregating tests which require a single threaded run..."
if [ ! -r ${SCRIPT_PWD}/known_bugs_tokumxse.strings ]; then
  echoit "Assert: ${SCRIPT_PWD}/known_bugs_tokumxse.strings not found?"
  exit 1
fi
cat ${SCRIPT_PWD}/known_bugs_tokumxse.strings | grep "|single[ \t]\+" | grep -v "^#" | sed 's/\(.*\)|single.*/\1/' > ${RESULTSDIR}/jstests_single.list
SINGLE_TEST_COUNT=$(cat ${RESULTSDIR}/jstests_single.list 2>/dev/null | wc -l)
if [ "${SINGLE_TEST_COUNT}" == "" ]; then SINGLE_TEST_COUNT=0; fi
echoit "${SINGLE_TEST_COUNT} Tests discovered which require a single threaded run. Segregating..."
while read line; do
  if [ $(grep -c $line ${RESULTSDIR}/jstests_single.list) -eq 0 ];then
    echo $line >> ${RESULTSDIR}/jstests.list.final
  fi
done < ${RESULTSDIR}/jstests.list
rm ${RESULTSDIR}/jstests.list
mv ${RESULTSDIR}/jstests.list.final ${RESULTSDIR}/jstests.list
TEST_COUNT=$(cat ${RESULTSDIR}/jstests.list 2>/dev/null | wc -l)
if [ "${TEST_COUNT}" == "" ]; then TEST_COUNT=0; fi
if [ ${TEST_COUNT} -lt 1000 ]; then  # Currently there are 1727 tests!
  echoit "Assert: The number of all JS tests (${TEST_COUNT}) is too small, check for build issues & verify contents of ${RESULTSDIR}/jstests.list!"
  exit 1
fi
echoit "Segregation complete. ${TEST_COUNT} (main) + ${SINGLE_TEST_COUNT} (single-threaded) JS tests armed..."

echoit "Starting MJR main test loop (non-segregated tests)..."
while true; do
  if [ -r ${RESULTSDIR}/ctrl_c_was_pressed_during_this_run ]; then break; fi
  while [ $(jobs -r | wc -l) -lt ${THREADS} ]; do  # Fixed 1 thread max
    if [ ${TEST_IN_PROGRESS} -ge ${TEST_COUNT} ]; then  # All tests done or started
      wait  # Wait for all current tests to finish
      break  # Exit inner loop
    fi
    start_thread
  done
  if [ ${TEST_IN_PROGRESS} -ge ${TEST_COUNT} ]; then  # All tests done or started
    wait  # Wait for all current tests to finish (more a safety net then anything)
    break  # Exit outer loop
  fi
done

echoit "Starting MJR main test loop (segregated single thread tests)..."
SEGREGATED=1
TEST_IN_PROGRESS=0
MUTEX1=0;MUTEX2=0
while true; do
  if [ -r ${RESULTSDIR}/ctrl_c_was_pressed_during_this_run ]; then break; fi
  while [ $(jobs -r | wc -l) -lt 1 ]; do  # Fixed 1 thread max
    if [ ${TEST_IN_PROGRESS} -ge ${SINGLE_TEST_COUNT} ]; then  # All tests done or started
      wait  # Wait for all current tests to finish
      break  # Exit inner loop
    fi
    start_thread
  done
  if [ ${TEST_IN_PROGRESS} -ge ${SINGLE_TEST_COUNT} ]; then  # All tests done or started
    wait  # Wait for all current tests to finish (more a safety net then anything)
    break  # Exit outer loop
  fi
done

echoit "Cleaning up any rogue processes..."
kill_pids

echoit "Done! Results are stored in the following directory: ${RESULTSDIR}"
exit 0
