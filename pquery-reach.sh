#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Updated to work with latest pquery framework structure (as of 13-08-2018)

# User variables
BASEDIR=/sda/MS300718-mysql-8.0.12-linux-x86_64-debug
THREADS=1
WORKDIR=/dev/shm
STATIC_PQUERY_BIN=/home/roel/percona-qa/pquery/pquery2-ps8  # Leave empty to use a random binary, i.e. percona-qa/pquery/pquery* 

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
if [ ! -r "${SCRIPT_PWD}/reducer.sh" ];            then echoit "Assert! reducer.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-run.sh" ];         then echoit "Assert! pquery-run.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-prep-red.sh" ];    then echoit "Assert! pquery-prep-red.sh not found!"; exit 1; fi
if [ ! -r "${SCRIPT_PWD}/pquery-clean-known.sh" ]; then echoit "Assert! pquery-clean-known.sh not found!"; exit 1; fi
if [ `ls ${SCRIPT_PWD}/pquery/*.sql 2>/dev/null | wc -l` -lt 1 ]; then echoit "Assert! No SQL input files found!" exit 1; fi

# Go!
export WORKDIR=${WORKDIR}/${RANDOMR}
if [ -d ${WORKDIR} ]; then WORKDIR=; echoit "Assert! ${WORKDIR} already exists. A random number collision?? Try and restart the script"; exit 1; fi
mkdir ${WORKDIR}
touch ${WORKDIR}/pquery-reach.log
echoit "pquery-reach (PID $$) working directory: ${WORKDIR} | Logfile: ${WORKDIR}/pquery-reach.log"

pquery_run(){
  cd ${SCRIPT_PWD}
  if [ ! -r $STATIC_PQUERY_BIN -o "${STATIC_PQUERY_BIN}" == "" ]; then
    # Select a random pquery binary
    PQUERY_BIN="$(ls ${SCRIPT_PWD}/pquery/pquery* | grep -vE "\.cfg|\.sql|\.oldv1|-pxc" | shuf --random-source=/dev/urandom | head -n1)"
    echoit "Randomly selected pquery binary: ${PQUERY_BIN}"
  else
    PQUERY_BIN=${STATIC_PQUERY_BIN}
    echoit "Static configured pquery binary: ${PQUERY_BIN}"
  fi

  # Select a random SQL file
  INFILE="$(ls ${SCRIPT_PWD}/pquery/*.sql ${SCRIPT_PWD}/pquery/main*.tar.xz | shuf --random-source=/dev/urandom | head -n1)"
  echoit "Randomly selected SQL input file: ${INFILE}"

  # Select a random mysqld options file
  # Using a random mysqld options file was found not to work well as many trials would get reduced but they were just a "bad option". Instead we should have a "Very common" subset of mysqld options and use that one (TODO). In the pquery-run.conf sed's below, this was also remarked so it can be unmarked once such a common set of options file is created, and this section can change to just use that file instead of randomly selecting one.
  #OPTIONS_INFILE="$(ls ${SCRIPT_PWD}/pquery/mysqld_options_*.txt | shuf --random-source=/dev/urandom | head -n1)"
  #echoit "Randomly selected mysqld options input file: ${INFILE}"

  # Select a random duration from 10 seconds to 3 minutes
  RANDOM=`date +%s%N | cut -b14-19`; PQUERY_RUN_TIMEOUT=$[$RANDOM % 170 + 10];
  echoit "Randomly selected trial duration: ${PQUERY_RUN_TIMEOUT} seconds"

  # pquery-run.sh setup and run
  RANDOM=`date +%s%N | cut -b14-19`; RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
  PQUERY_RUN=${WORKDIR}/${RANDOMD}_pquery-run.sh
  PQUERY_CONF_FILE=${RANDOMD}_pquery-run.conf
  PQUERY_CONF=${WORKDIR}/${PQUERY_CONF_FILE}
  PQR_WORKDIR=${WORKDIR}/${RANDOMD}
  PQR_RUNDIR=${WORKDIR}/RUNDIR_${RANDOMD}
  cat ${SCRIPT_PWD}/pquery-run.sh |
   sed "s|\${SCRIPT_PWD}/generator|${SCRIPT_PWD}/generator|g" | \
   sed "s|\${SCRIPT_PWD}/text_string.sh|${SCRIPT_PWD}/text_string.sh|g" | \
   sed "s|\${SCRIPT_PWD}/valgrind_string.sh|${SCRIPT_PWD}/valgrind_string.sh|g" | \
   sed "s|\${SCRIPT_PWD}/vault_test_setup.sh|${SCRIPT_PWD}/vault_test_setup.sh|g" | \
   sed "s|\${SCRIPT_PWD}/ldd_files.sh|${SCRIPT_PWD}/ldd_files.sh|g" | \
   sed "s|\${SCRIPT_PWD}/sysbench|${SCRIPT_PWD}/sysbench|g" > ${PQUERY_RUN}
  sed -i "4 iSKIPCHECKDIRS=1" ${PQUERY_RUN}  # TODO: check if there is a better way then skipping some safety checks in pquery-run.sh
  cat ${SCRIPT_PWD}/pquery-run.conf |
   sed "s|^[ \t]*PQUERY_BIN=.*|PQUERY_BIN=${PQUERY_BIN}|" | \
   sed "s|^[ \t]*INFILE=.*|INFILE=${INFILE}|" | \
   #sed "s|^[ \t]*INFILE=.*|INFILE=~/percona-qa/pquery/main.sql|" | \
   sed "s|^[ \t]*OPTIONS_INFILE=.*|OPTIONS_INFILE=${OPTIONS_INFILE}|" | \
   sed "s|^[ \t]*ADD_RANDOM_OPTIONS=.*|ADD_RANDOM_OPTIONS=0|" | \
   #sed "s|^[ \t]*ADD_RANDOM_OPTIONS=.*|ADD_RANDOM_OPTIONS=1|" | \
   sed "s|^[ \t]*MAX_NR_OF_RND_OPTS_TO_ADD=.*|MAX_NR_OF_RND_OPTS_TO_ADD=0|" | \
   #sed "s|^[ \t]*MAX_NR_OF_RND_OPTS_TO_ADD=.*|MAX_NR_OF_RND_OPTS_TO_ADD=2|" | \
   sed "s|^[ \t]*ADD_RANDOM_TOKUDB_OPTIONS=.*|ADD_RANDOM_TOKUDB_OPTIONS=0|" | \
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
   sed "s|^[ \t]*SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=.*|SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=1|" | \
   sed "s|^[ \t]*SAVE_SQL=.*|SAVE_SQL=0|" | \
   sed "s|^[ \t]*MYSQLD_START_TIMEOUT.*|MYSQLD_START_TIMEOUT=60|" | \
   sed "s|^[ \t]*MULTI_THREADED_RUN=.*|MULTI_THREADED_RUN=$(if [ ${THREADS} -gt 1 ]; then echo '1'; else echo '0'; fi)|" | \
   sed "s|^[ \t]*QUERIES_PER_THREAD=.*|QUERIES_PER_THREAD=2147483647|" | \
   sed "s|^[ \t]*PQUERY_RUN_TIMEOUT=.*|PQUERY_RUN_TIMEOUT=${PQUERY_RUN_TIMEOUT}|" | \
   sed "s|^[ \t]*THREADS=.*|THREADS=${THREADS}|" | \
   sed "s|^[ \t]*MULTI_THREADED_TESTC_LINES=.*|MULTI_THREADED_TESTC_LINES=20000|" > ${PQUERY_CONF}
  chmod +x ${PQUERY_RUN}
  echoit "Starting: ${PQUERY_RUN}..."
  echoit "=================================================================================================================="
  ${PQUERY_RUN} ${PQUERY_CONF_FILE} | tee -a ${WORKDIR}/pquery-reach.log
  echoit "=================================================================================================================="
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
        if grep -qi "^MODE=3" ${PQR_WORKDIR}/reducer1.sh; then
          echoit "New, and specific (MODE=3) bug found! Reducing the same..."
          # Approximately matching pquery-go-expert.sh settings 
          sed -i "s|^FORCE_SKIPV=0|FORCE_SKIPV=1|" ${PQR_WORKDIR}/reducer1.sh  # Setting this DOES mean the script will not terminate fully (but will stay in reduction mode) - why is reducer not stopping after STAGE1_LINES have been reached?
          sed -i "s|^MULTI_THREADS=[0-9]\+|MULTI_THREADS=3 |" ${PQR_WORKDIR}/reducer1.sh
          sed -i "s|^MULTI_THREADS_INCREASE=[0-9]\+|MULTI_THREADS_INCREASE=3|" ${PQR_WORKDIR}/reducer1.sh
          sed -i "s|^MULTI_THREADS_MAX=[0-9]\+|MULTI_THREADS_MAX=9 |" ${PQR_WORKDIR}/reducer1.sh
          sed -i "s|^STAGE1_LINES=[0-9]\+|STAGE1_LINES=13|" ${PQR_WORKDIR}/reducer1.sh
          echoit "=================================================================================================================="
          ${PQR_WORKDIR}/reducer1.sh | tee -a ${WORKDIR}/pquery-reach.log
          echoit "=================================================================================================================="
          echoit "Cleaning up reducer workdir..."
          REDUCER_WORKDIR=$(grep '\[Init\] Workdir' ${WORKDIR}/pquery-reach.log | sed "s|.*:[ \t]*||")
          if [ -d "${REDUCER_WORKDIR}" ]; then
            rm -Rf ${REDUCER_WORKDIR}
          fi
          echoit "pquery-reach.sh complete, new bug found and reduced! Exiting normally..."
          exit 0
        else
          if [ -r ${PQR_WORKDIR}/1/log/master.err ]; then
            if grep -qi "nknown variable" ${PQR_WORKDIR}/1/log/master.err; then
              echoit "This run had an invalid/unknown mysqld variable (dud), cleaning up & trying again..."
              rm -Rf ${PQR_WORKDIR}; rm -Rf ${PQR_RUNDIR}; rm -Rf ${PQUERY_RUN}; PQR_WORKDIR=; PQR_RUNDIR=; PQUERY_RUN=;  # Cleanup
              main_loop
            else
              if [ `ls ${PQR_WORKDIR}/1/data/*core* 2>/dev/null | wc -l` -lt 1 ]; then 
                echoit "No error log found, and no core found. Likely some SQL was executed like 'RELEASE' or 'SHUTDOWN', cleaning up & trying again..."
                rm -Rf ${PQR_WORKDIR}; rm -Rf ${PQR_RUNDIR}; rm -Rf ${PQUERY_RUN}; PQR_WORKDIR=; PQR_RUNDIR=; PQUERY_RUN=;  # Cleanup
                main_loop
              else
                echoit "No error log AND no core found. Odd... TODO"
                exit 1
              fi
            fi
          else
            echoit "New, and non-specific (MODE=4) bug found! Terminating for manual analysis..."
            echoit "Use: $ cd ${WORKDIR}; vi reducer1.sh   # To get started!"
            exit 0
          fi
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
