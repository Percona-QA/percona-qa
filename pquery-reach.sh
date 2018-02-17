#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# User variables
BASEDIR=/sda/percona-5.6.22-71.0-linux-x86_64-debug
THREADS=1
WORKDIR=/dev/shm

# Internal variables: Do not change!
RANDOM=`date +%s%N | cut -b14-19`; RANDOMR=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
SCRIPT_PWD=$(cd `dirname $0` && pwd)

echoit(){
  echo "[$(date +'%T')] === $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] === $1" >> ${WORKDIR}/pquery-reach.log; fi
}

# Trap ctrl-c
trap ctrl-c SIGINT

ctrl-c(){
  echoit "CTRL+C Was pressed. Attempting to terminate running processes..."
  KILL_PIDS=`ps -ef | grep "$RANDOMR" | grep -v "grep" | awk '{print $2}' | tr '\n' ' '`
  if [ "${KILL_PIDS}" != "" ]; then
    echoit "Terminating the following PID's: ${KILL_PIDS}"
    kill -9 ${KILL_PIDS} >/dev/null 2>&1
  fi
  echoit "Done. Terminating pquery-run.sh with exit code 2..."
  exit 2
}

# Make sure we've got all items we need
if [ ! -r "${SCRIPT_PWD}/pquery-run.sh" ];         then echoit "Assert! pquery-run.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-prep-red.sh" ];    then echoit "Assert! pquery-prep-red.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-clean-known.sh" ]; then echoit "Assert! pquery-clean-known.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery/pquery2-ps" ];     then echoit "Assert! pquery-ps not found!" exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery/pquery2-ms" ];     then echoit "Assert! pquery-ms not found!" exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery/pquery2-md" ];     then echoit "Assert! pquery-md not found!" exit 1; fi
if [ `ls ${SCRIPT_PWD}/pquery/*.sql 2>/dev/null | wc -l` -lt 1 ]; then echoit "Assert! No SQL input files found!" exit 1; fi

# Make sure we have sub-script tools in place
REDUCER="`grep "REDUCER=" ${SCRIPT_PWD}/pquery-prep-red.sh | grep -o '=.*' | sed 's|[="]||g'`"
if [ ! -r "${REDUCER}" ]; then echoit "Assert! reducer.sh (as configured in ${SCRIPT_PWD}/pquery-prep-red.sh) not found!"; exit 1; fi

# Go!
export WORKDIR=${WORKDIR}/${RANDOMR}
echoit "pquery-reach (PID $$) working directory: ${WORKDIR}"
if [ -d ${WORKDIR} ]; then WORKDIR=; echoit "Assert! ${WORKDIR} already exists. A random number collision?? Try and restart the script"; exit 1; fi
mkdir ${WORKDIR}

pquery_run(){
  cd ${SCRIPT_PWD}
  # Select a random pquery
  PQUERY_BIN="${SCRIPT_PWD}/pquery/pquery-"
  RANDOM=`date +%s%N | cut -b14-19`; case $[$RANDOM % 3 + 1] in 1) PQUERY_BIN="${PQUERY_BIN}ps";; 2) PQUERY_BIN="${PQUERY_BIN}ms";; 3) PQUERY_BIN="${PQUERY_BIN}md";; esac
  echoit "Randomly selected pquery binary: ${PQUERY_BIN}"

  # Select a random SQL file
  RANDOM=`date +%s%N | cut -b14-19`; INFILE="$(ls ${SCRIPT_PWD}/pquery/*.sql | shuf --random-source=/dev/urandom | head -n1)"
  echoit "Randomly selected SQL input file: ${INFILE}"

  # Select a random duration from 10 seconds to 3 minutes
  RANDOM=`date +%s%N | cut -b14-19`; PQUERY_RUN_TIMEOUT=$[$RANDOM % 170 + 10];
  echoit "Randomly selected trial duration: ${PQUERY_RUN_TIMEOUT} seconds"

  # pquery-run.sh setup and run
  RANDOM=`date +%s%N | cut -b14-19`; RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
  PQUERY_RUN=${WORKDIR}/${RANDOMD}_pquery-run.sh
  PQR_WORKDIR=${WORKDIR}/${RANDOMD}_WORKDIR
  PQR_RUNDIR=${WORKDIR}/${RANDOMD}_RUNDIR
  cat ${SCRIPT_PWD}/pquery-run.sh | 
  sed "s|^[ \t]*PQUERY_BIN=.*|PQUERY_BIN=${PQUERY_BIN}|" | \
  sed "s|^[ \t]*INFILE=.*|INFILE=${INFILE}|" | \
  #sed "s|^[ \t]*INFILE=.*|INFILE=~/percona-qa/pquery/main.sql|" | \
  sed "s|^[ \t]*RANDOMD=.*|RANDOMD=${RANDOMD}|" | \
  sed "s|^[ \t]*WORKDIR=.*|WORKDIR=${PQR_WORKDIR}|" | \
  sed "s|^[ \t]*BASEDIR=.*|BASEDIR=${BASEDIR}|" | \
  sed "s|^[ \t]*RUNDIR=.*|RUNDIR=${PQR_RUNDIR}|" | \
  sed "s|^[ \t]*SCRIPT_PWD=.*|SCRIPT_PWD=${SCRIPT_PWD}|" | \
  sed "s|^[ \t]*PXC=.*|PXC=0|" | \
  sed "s|^[ \t]*ARCHIVE_INFILE_COPY=.*|ARCHIVE_INFILE_COPY=0|" | \
  sed "s|^[ \t]*DOCKER=.*|DOCKER=0|" | \
  sed "s|^[ \t]*TRIALS=.*|TRIALS=1|" | \
  sed "s|^[ \t]*VALGRIND_RUN=.*|VALGRIND_RUN=0|" | \
  sed "s|^[ \t]*SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=.*|SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=0|" | \
  sed "s|^[ \t]*SAVE_SQL=.*|SAVE_SQL=0|" | \
  sed "s|^[ \t]*MYSQLD_START_TIMEOUT.*|MYSQLD_START_TIMEOUT=60|" | \
  sed "s|^[ \t]*MULTI_THREADED_RUN=.*|MULTI_THREADED_RUN=$(if [ ${THREADS} -gt 1 ]; then echo '1'; else echo '0'; fi)|" | \
  sed "s|^[ \t]*QUERIES_PER_THREAD=.*|QUERIES_PER_THREAD=2147483647|" | \
  sed "s|^[ \t]*PQUERY_RUN_TIMEOUT=.*|PQUERY_RUN_TIMEOUT=${PQUERY_RUN_TIMEOUT}|" | \
  sed "s|^[ \t]*THREADS=.*|THREADS=${THREADS}|" | \
  sed "s|^[ \t]*MULTI_THREADED_TESTC_LINES=.*|MULTI_THREADED_TESTC_LINES=20000|" > ${PQUERY_RUN}
 chmod +x ${PQUERY_RUN}
 echoit "Starting: ${PQUERY_RUN}..."
 echoit "========================================================================================================================================"
 ${PQUERY_RUN} | tee -a ${WORKDIR}/pquery-reach.log
 echoit "========================================================================================================================================"
}

main_loop(){
  pquery_run
  if [ -d ${PQR_WORKDIR}/1 ]; then
    echoit "Found bug at ${PQR_WORKDIR}/1, preparing reducer for it using pquery-prep-red.sh..."
    cd ${PQR_WORKDIR}
    ${SCRIPT_PWD}/pquery-prep-red.sh reach | sed "s|^|[$(date +'%T')] === |" | tee -a ${WORKDIR}/pquery-reach.log
    echoit "Filtering known bugs using pquery-clean-known.sh..."
    ${SCRIPT_PWD}/pquery-clean-known.sh reach | sed "s|^|[$(date +'%T')] === |" | tee -a ${WORKDIR}/pquery-reach.log
    if [ -d ${PQR_WORKDIR}/1 ]; then
      if [ -r ${PQR_WORKDIR}/reducer1.sh ]; then
        if grep -qi "MODE=3" ${PQR_WORKDIR}/reducer1.sh; then
          echoit "New, and specific (MODE=3) bug found! Reducing the same..."
          sed -i "s|$MULTI_THREADS -ge 51|$MULTI_THREADS -ge 16|" ${PQR_WORKDIR}/reducer1.sh
          echoit "========================================================================================================================================"
          ${PQR_WORKDIR}/reducer1.sh | tee -a ${WORKDIR}/pquery-reach.log
          echoit "========================================================================================================================================"
          echoit "Cleaning up reducer workdir..."
          REDUCER_WORKDIR=$(grep '\[Init\] Workdir' ${WORKDIR}/pquery-reach.log | sed "s|.*:[ \t]*||")
          if [ -d "${REDUCER_WORKDIR}" ]; then
            rm -Rf ${REDUCER_WORKDIR}
          fi
          echoit "pquery-reach.sh complete, new bug found and reduced! Exiting normally..."
          exit 0
        else
          echoit "New, and non-specific (MODE=4) bug found! Terminating for manual analysis..."
          echoit "Use: $ cd ${WORKDIR}; vi reducer1.sh   # To get started!"
          exit 0
        fi
      fi
    else
      echoit "This bug was filtered (already logged), cleaning up & trying again..."
      rm -Rf ${PQR_WORKDIR}; rm -Rf ${PQR_RUNDIR}; rm -Rf ${PQUERY_RUN}; PQR_WORKDIR=; PQR_RUNDIR=; PQUERY_RUN=;  # Cleanup 
      main_loop 
    fi
  else
    echoit "No bug found, cleaning up & trying again..."
    rm -Rf ${PQR_WORKDIR}; rm -Rf ${PQR_RUNDIR}; rm -Rf ${PQUERY_RUN}; PQR_WORKDIR=; PQR_RUNDIR=; PQUERY_RUN=;  # Cleanup 
    main_loop
  fi
}

main_loop
