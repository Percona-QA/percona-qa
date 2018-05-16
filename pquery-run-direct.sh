#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Internal variables: please do not change! Ref below for user configurable variables
RANDOM=`date +%s%N | cut -b14-19`                             # RANDOM: Random entropy pool init. RANDOMD (below): Random number generator (6 digits)
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
SCRIPT_PWD=$(cd `dirname $0` && pwd)
TRIAL=0

# User Configurable Variables
PQUERY_BIN=${SCRIPT_PWD}/pquery/pquery            # pquery/pquery-ps for Percona Server, .../pquery-ms for MySQL, .../pquery-md for MariaDB, pquery-ws for WebScaleSQL
INFILE=${SCRIPT_PWD}/pquery/main-ms-ps-md.sql     # Default: main-ms-ps-md.sql (mtr_to_sql.sh of all major distro's + engine mix)
WORKDIR=/tmp/$RANDOMD                             # Work directory - here the log is stored, as well as the SQL used per-trial
TRIALS=10000                                      # Number of trials to execute
PQUERY_RUN_TIMEOUT=300                            # x sec pquery trial runtime (in this it will try to process ${QUERIES_PER_THREAD} x ${THREADS} queries - against 1 mysqld)
                                                  # This timeout is a "hard timeout"; it uses timeout command & kill -9: i.e. no pquery log will be available in this case
QUERIES_PER_THREAD=100000                         # Queries per client thread
THREADS=50                                        # Number of client threads
HOST=127.0.0.1                                    # IP Address of the target host
PORT=16327                                        # Port of the target host
USER="root"                                       # MySQL Username on the target host
PASSWORD=""                                       # Password on the target host
DATABASE=test                                     # Database on the target host. It's highly recommended to use 'test' as the SQL input file references it many times. If you
                                                  # need to use another database if name, it's best to:  sed -i "s|test|somedb|g" ${INFILE}  or similar (may lower SQL quality!)

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> /${WORKDIR}/pquery-run-direct.log; fi
}

# Trap ctrl-c
trap ctrl-c SIGINT

ctrl-c(){
  echoit "CTRL+C Was pressed. Terminating run..."
  echoit "The results of this run can be found in the workdir ${WORKDIR}"
  echoit "Log file is available at ${WORKDIR}/pquery-run-direct.log"
  echoit "Terminating pquery-run-direct.sh with exit code 2..."
  exit 2
}

# Commence testing
mkdir -p ${WORKDIR}
touch ${WORKDIR}/test
if [ ! -r ${WORKDIR}/test ]; then
  echoit "Assert: this script tried to create the following directory and file: ${WORKDIR}/test, yet the file did not exist after the creation attempt. Please check privileges of this script for the/in ${WORKDIR}. Also please check for out of disk space, and similar issues"
else
  rm ${WORKDIR}/test
fi
echoit "pquery-run-direct.sh v0.01"
echoit "Running against server/database at ${USER}:PASSWORD@${HOST}:${PORT}/${DATABASE}"
echoit "Using ${THREADS} thread(s), with up to ${QUERIES_PER_THREAD} queries/thread, with a timeout (kill -9) at ${PQUERY_RUN_TIMEOUT} sec"
echoit "Storing results to ${WORKDIR}, log is at ${WORKDIR}/pquery-run-direct.log"
echoit "[Init] Pre-processing SQL input file; removing any references to root userID to avoid lockout..."
echoit "[Init] Source: ${INFILE} | Target: ${WORKDIR}/input.sql"
echoit "[Init] Note that further filters may be necessary depending on runtime findings..."
egrep -vi "root|user.*%|%.*user" ${INFILE} > ${WORKDIR}/input.sql
if [ ! -r  ${WORKDIR}/input.sql ]; then
  echoit "Assert: this script tried to create a filtered input file (${WORKDIR}/input.sql) based on ${INPUT}, but afterwards the resulting file ${WORKDIR}/input.sql was not available. Please check for out of disk space, and similar issues"
fi
while true; do
  TRIAL=$[ ${TRIAL} + 1 ]
  echoit "[Trial ${TRIAL}] Commencing trial #${TRIAL}, log is at ${WORKDIR}/${TRIAL}/pquery.log"
  mkdir -p ${WORKDIR}/${TRIAL}
  touch ${WORKDIR}/${TRIAL}/test
  if [ ! -r ${WORKDIR}/${TRIAL}/test ]; then
    echoit "[Trial ${TRIAL}] Assert: this script tried to create the following directory and file: ${WORKDIR}/${TRIAL}/test, yet the file did not exist after the creation attempt. Please check privileges of this script for the/in ${WORKDIR}. Also please check out of disk space, and similar"
  else
    rm ${WORKDIR}/${TRIAL}/test
  fi
   echoit "[Trial ${TRIAL}] Processing ${QUERIES_PER_THREAD} queries accross ${THREADS} thread(s) with a timeout of ${PQUERY_RUN_TIMEOUT} seconds..."
   timeout --signal=9 ${PQUERY_RUN_TIMEOUT}s ${PQUERY_BIN} --address=${HOST} --port=${PORT} --user=${USER} --password=${PASSWORD} --infile=${INFILE} --database=${DATABASE} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${WORKDIR}/${TRIAL} --log-all-queries --log-failed-queries >${WORKDIR}/${TRIAL}/pquery.log 2>&1
   if egrep -qi "Last.*consecutive queries all failed" ${WORKDIR}/${TRIAL}/pquery.log; then
     echoit "[Trial ${TRIAL}] pquery reported that last set of queries all failed. This could be a crash/assert, user privileges drop, or similar! Error from pquery log:"
     grep "Last.*consecutive queries all failed" ${WORKDIR}/${TRIAL}/pquery.log | head -n1
     echoit "[Trial ${TRIAL}] Terminating!"
     exit 0
   fi
   if egrep -qi "Can.t connect to MySQL server" ${WORKDIR}/${TRIAL}/pquery.log; then
     echoit "[Trial ${TRIAL}] Unable to connect to MySQL server! Potentially incorrect settings, crash/assert, user privileges drop, or similar! Error from pquery log:"
     grep "Can.t connect to MySQL server" ${WORKDIR}/${TRIAL}/pquery.log | head -n1
     echoit "[Trial ${TRIAL}] Terminating!"
     exit 1
   fi
   if egrep -qi "Access denied for user" ${WORKDIR}/${TRIAL}/pquery.log; then
     echoit "[Trial ${TRIAL}] Authentication denied - check credentials! Error from pquery log:"
     grep "Access denied for user" ${WORKDIR}/${TRIAL}/pquery.log | head -n1
     echoit "[Trial ${TRIAL}] Terminating!"
     exit 1
   fi
   if egrep -qi "Too many connections" ${WORKDIR}/${TRIAL}/pquery.log; then
     echoit "[Trial ${TRIAL}] Connection failed - MySQL server reports 'Too many connections' - this is a known issue! Recommend action: restart server. Error from pquery log:"
     grep "Too many connections" ${WORKDIR}/${TRIAL}/pquery.log | head -n1
     echoit "[Trial ${TRIAL}] Terminating!"
     exit 1
   fi
   if egrep -qi "Host.*is not allowed to connect to this MySQL server" ${WORKDIR}/${TRIAL}/pquery.log; then
     echoit "[Trial ${TRIAL}] Connection failed - MySQL server reports 'Host is not allowed to connect to this MySQL server' - check mysql side priviliges (likely there is no ${USER}@% account or similar)"
     grep "Host.*is not allowed to connect to this MySQL server" ${WORKDIR}/${TRIAL}/pquery.log | head -n1
     echoit "[Trial ${TRIAL}] Terminating!"
     exit 1
   fi
done

