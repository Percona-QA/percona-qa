#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Updated by Roel Van de Paar, Percona LLC

# Start this script from within the base directory which contains ./bin/mysqld[-debug]

# User configurable variables
WORKDIR="/dev/shm"                               ## Working directory ("/dev/shm" preferred)
SQLFILE="./test.sql"                             ## SQL Input file
MYEXTRA="--no-defaults --event-scheduler=ON"     ## MYEXTRA: Extra --options required for msyqld (may not be required)
SERVER_THREADS=(10 20 30 40)                     ## Number of server threads (x mysqld's). This is a sequence: (10 20) means: first 10, then 20 server if no crash was observed
CLIENT_THREADS=1                                 ## Number of client threads (y threads) which will execute the SQLFILE input file against each mysqld
AFTER_SHUTDOWN_DELAY=240                         ## Wait this many seconds for mysqld to shutdown properly. If it does not shutdown within the allotted time, an error shows

# Internal variables
MYUSER=$(whoami)
MYPORT=$[20000 + $RANDOM % 9999 + 1]
DATADIR=`date +'%s'`

# Reference functions
echoit(){ echo "[$(date +'%T')] $1"; }

if [ ! -r ${SQL_FILE} ]; then
  echoit "Assert: this script tried to read ${SQL_FILE} (as specified in the  \"User configurable variables\" at the top of/inside the script), but it could not."
  echoit "Please check if the file exists, if this script can read it, etc."
  exit 1
fi

if [ ! -d ${WORKDIR} ]; then
  echoit "Assert: {$WORKDIR} (as specified in the  \"User configurable variables\" at the top of/inside the script) does not exist!"
  exit 1
else  # Workdir setup
  WORKDIR="${WORKDIR}/$DATADIR"
  mkdir -p ${WORKDIR}
  if [ ! -d ${WORKDIR} ]; then
    echoit "Assert: we tried to create ${WORKDIR}, but it does not exist after the creation attempt! Has this script write privileges there?"
    exit 1
  fi
fi

if [ -r ${PWD}/bin/mysqld ]; then
  BIN=${PWD}/bin/mysqld
else
  # Check if this is a debug build by checking if debug string is present in dirname
  if [[ ${PWD} = *debug* ]]; then
    if [ -r ${PWD}/bin/mysqld-debug ]; then
      BIN=${PWD}/bin/mysqld-debug
    else
      echoit "Assert: there is no (script readable) mysqld binary at ${PWD}/bin/mysqld[-debug] ?"
      exit 1
    fi
  else
    echoit "Assert: there is no (script readable) mysqld binary at ${PWD}/bin/mysqld ?"
    exit 1
  fi
fi

echoit "Script work directory : ${WORKDIR}"
# Get version specific options
BIN=
if [ -r ${PWD}/bin/mysqld-debug ]; then BIN="${PWD}/bin/mysqld-debug"; fi  # Needs to come first so it's overwritten in next line if both exist
if [ -r ${PWD}/bin/mysqld ]; then BIN="${PWD}/bin/mysqld"; fi
if [ "${BIN}" == "" ]; then echo "Assert: no mysqld or mysqld-debug binary was found!"; fi
MID=
if [ -r ${PWD}/scripts/mysql_install_db ]; then MID="${PWD}/scripts/mysql_install_db"; fi
if [ -r ${PWD}/bin/mysql_install_db ]; then MID="${PWD}/bin/mysql_install_db"; fi
START_OPT="--core-file"           # Compatible with 5.6,5.7,8.0
INIT_OPT="--initialize-insecure"  # Compatible with     5.7,8.0 (mysqld init)
INIT_TOOL="${BIN}"                # Compatible with     5.7,8.0 (mysqld init), changed to MID later if version <=5.6
VERSION_INFO=$(${BIN} --version | grep -oe '[58]\.[01567]' | head -n1)
if [ "${VERSION_INFO}" == "5.1" -o "${VERSION_INFO}" == "5.5" -o "${VERSION_INFO}" == "5.6" ]; then
  if [ "${MID}" == "" ]; then
    echo "Assert: Version was detected as ${VERSION_INFO}, yet ./scripts/mysql_install_db nor ./bin/mysql_install_db is present!"
    exit 1
  fi
  INIT_TOOL="${MID}"
  INIT_OPT="--force --no-defaults"
  START_OPT="--core"
elif [ "${VERSION_INFO}" != "5.7" -a "${VERSION_INFO}" != "8.0" ]; then
  echo "WARNING: mysqld (${BIN}) version detection failed. This is likely caused by using this script with a non-supported distribution or version of mysqld. Please expand this script to handle (which shoud be easy to do). Even so, the scipt will now try and continue as-is, but this may fail."
fi

# Run SQL file from reducer<trial>.sh
SERVER_COUNT=0
for i in ${SERVER_THREADS[@]};do
  MYSQLD=()
  MYSQLC=()
  # Start multiple mysqld service
  for j in `seq 1 ${i}`;do
    SERVER_COUNT=$[ ${SERVER_COUNT} + 1 ];
    echoit "Starting mysqld #${SERVER_COUNT}..."
    MYPORT=$[ ${MYPORT} + 1 ]
    $INIT_TOOL ${INIT_OPT} --basedir=${PWD} --datadir=${PWD}/data > ${WORKDIR}/${j}_mysql_install_db.out 2>&1
    mkdir ${WORKDIR}/${j} 2>/dev/null
    CMD="bash -c \"set -o pipefail; ${BIN} ${MYEXTRA} ${START_OPT} --basedir=${PWD} --datadir=${WORKDIR}/${j} --port=${MYPORT}
         --pid-file=${WORKDIR}/${j}_pid.pid --log-error=${WORKDIR}/${j}_error.log.out --socket=${WORKDIR}/${j}_socket.sock --user=${MYUSER}\""
    eval $CMD > ${WORKDIR}/${j}_mysqld.out 2>&1 &
    PIDV="$!"
    MYSQLD+=(${PIDV})
  done
  for j in `seq 1 ${i}`;do
    x=0
    ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1
    CHECK=$?
    while [[ $CHECK != 0 ]]; do
      ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1
      CHECK=$?
      sleep 1
      if [ $x == 60 ];then
        echoit "[ERROR] Server not started: Check ${WORKDIR}/${j}_mysql_install_db.out, ${WORKDIR}/${j}_error.log.out and ${WORKDIR}/${j}_mysqld.out for more info"
        exit 1;
      fi
      x=$[ $x+1 ]
    done
  done
  # Start multiple mysql clients to test the SQL
  for j in `seq 1 ${i}`;do
    ## The following line is for pquery testing
    #$(cd `dirname $0` && pwd)/pquery/pquery --infile=${TRIAL}.out_out --database=test --threads=5 --user=root --socket=${WORKDIR}/${j}_socket.sock > ${WORKDIR}/script_sql_out_${j} 2>&1 &
    echoit "Starting ${CLIENT_THREADS} client threads against mysqld # ${j}..."
    for (( thread=1; thread<=${CLIENT_THREADS}; thread++ )); do
      ${PWD}/bin/mysql -uroot --socket=${WORKDIR}/${j}_socket.sock -f < ${SQLFILE} > multi.$thread 2>&1 &
      PID="$!"
      MYSQLC+=($PID)
    done
    # Check if mysqld process crashed immediately
    if ! ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
      echoit "[!] Server crash/shutdown found : Check ${WORKDIR}/${j}_error.log.out for more info"
      exit 1
    fi
  done
  # Check if mysql client finished
  for k in "${MYSQLC[@]}"; do
    while [[ ( -d /proc/$k ) && ( -z `grep zombie /proc/$k/status` ) ]]; do
      sleep 1
      # Check mysqld processes while waiting for client processes to finish
      TO_EXIT=0
      for j in `seq 1 ${i}`;do
        if ! ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
          echoit "[!] Server crash/shutdown found: Check ${WORKDIR}/${j}_error.log.out for more info"
          TO_EXIT=1
        fi
      done
      if [ ${TO_EXIT} -eq 1 ]; then exit 1; fi
    done
  done
  # Check mysqld processes after client processes are done
  TO_EXIT=0
  for j in `seq 1 ${i}`;do
    if ! ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
      echoit "[!] Server crash/shutdown found: Check ${WORKDIR}/${j}_error.log.out for more info"
      TO_EXIT=1
    fi
  done
  # Shutdown mysqld processes
  for j in `seq 1 ${i}`;do
    echoit "Shutting down mysqld #${j}..."
    ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock shutdown > /dev/null 2>&1 &
  done
  sleep ${AFTER_SHUTDOWN_DELAY}
  # Check for shutdown issues
  TO_EXIT=0
  for j in `seq 1 ${i}`;do
    if ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
      echoit "[!] Server hang found: mysqld #{j} has not shutdown in ${AFTER_SHUTDOWN_DELAY} seconds. Check ${WORKDIR}/${j}_error.log.out for more info"
      TO_EXIT=1
    fi
    if [ $(ls ${WORKDIR}/${j}/*core* 2>/dev/null | grep -vi "no such file or directory" | wc -l) -gt 0 ]; then
      echoit "[!] Server crash found: Check ${WORKDIR}/${j}_error.log.out and $(ls -l ${WORKDIR}/${j}/*core* | tr '\n' ' ') for more info"
      TO_EXIT=1
    fi
  done
  if [ ${TO_EXIT} -eq 1 ]; then exit 1; fi
  if [ ${SERVER_THREADS[@]:(-1)} -ne ${i} ] ; then
   echoit "Did not find server crash with ${i} mysqld processes. Restarting crash test with next set of mysqld processes."
   kill -9 `printf '%s ' "${MYSQLD[@]}"` 
   rm -Rf ${WORKDIR}/*
  else
   kill -9 `printf '%s ' "${MYSQLD[@]}"` 
  fi
done
