#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Updated by Roel Van de Paar, Percona LLC

# User configurable variables
WORKDIR="/dev/shm"                               ## Working directory ("/dev/shm" preferred)
MYBASE="${PWD}"                                  ## mysqld Base Directory. If referencing this script from the base directory, use "${PWD}"
SQLFILE="./test.sql"                             ## SQL Input file
MYEXTRA="--no-defaults --event-scheduler=ON"     ## MYEXTRA: Extra --options required for msyqld (may not be required)
SERVER_THREADS=(10 20 30 40)                     ## Number of server threads (x mysqld's). This is a sequence: (10 20) means: first 10, then 20 server if no crash was observed
CLIENT_THREADS=1                                 ## Number of client threads (y threads) which will execute the SQLFILE input file against each mysqld
AFTER_SHUTDOWN_DELAY=240                         ## Wait this many seconds for mysqld to shutdown properly. If it does not shutdown within the allotted time, an error shows
TOKUDB_REQUIRED=0                                ## Set to 1 if TokuDB is required

# Internal variables
MYUSER=$(whoami)
MYPORT=$[20000 + $RANDOM % 9999 + 1]
DATADIR=`date +'%s'`
SERVER_THREADS=(10 20 30)

# Reference functions
echoit(){ echo "[$(date +'%T')] $1"; }

if [ ${TOKUDB_REQUIRED} -ne 0 -a ${TOKUDB_REQUIRED} -ne 1 ]; then
  echoit "Something is wrong: TOKUDB_REQUIRED is set to ${TOKUDB_REQUIRED}, but that is not a valid option. Use 0 (TokuDB not required), or 1 (TokuDB required)"
  exit 1
fi

if [ ! -r ${SQL_FILE} ]; then
  echoit "Something is wrong: this script tried to read ${SQL_FILE} (as specified in the  \"User configurable variables\" at the top of/inside the script), but it could not."
  echoit "Please check if the file exists, if this script can read it, etc."
  exit 1
fi

if [ ! -d ${WORKDIR} ]; then
  echoit "Something is wrong: {$WORKDIR} (as specified in the  \"User configurable variables\" at the top of/inside the script) does not exist!"
  exit 1
else  # Workdir setup
  WORKDIR="${WORKDIR}/$DATADIR"
  mkdir -p ${WORKDIR}
  if [ ! -d ${WORKDIR} ]; then
    echoit "Something is wrong: we tried to create ${WORKDIR}, but it does not exist after the creation attempt! Has this script write privileges there?"
    exit 1
  fi
fi

if [ -r ${MYBASE}/bin/mysqld ]; then
  BIN=${MYBASE}/bin/mysqld
else
  # Check if this is a debug build by checking if debug string is present in dirname
  if [[ ${MYBASE} = *debug* ]]; then
    if [ -r ${MYBASE}/bin/mysqld-debug ]; then
      BIN=${MYBASE}/bin/mysqld-debug
    else
      echoit "Something is wrong: there is no (script readable) mysqld binary at ${MYBASE}/bin/mysqld[-debug] ?"
      exit 1
    fi
  else
    echoit "Something is wrong: there is no (script readable) mysqld binary at ${MYBASE}/bin/mysqld ?"
    exit 1
  fi
fi

#Load jemalloc library for TokuDB engine
if [ ${TOKUDB_REQUIRED} -eq 1 ]; then
  if [ -r /usr/lib64/libjemalloc.so.1 ]; then
    export LD_PRELOAD=/usr/lib64/libjemalloc.so.1
  elif [ -r /usr/lib/x86_64-linux-gnu/libjemalloc.so.1 ]; then
    export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.1
  elif [ -r ${PWD}/lib/mysql/libjemalloc.so.1 ]; then
    export LD_PRELOAD=${PWD}/lib/mysql/libjemalloc.so.1
  else
    echoit 'Error: jemalloc not found, please install it first';
    exit 1;
  fi
fi

echoit "Script work directory : ${WORKDIR}"
# Get version specific options. MID=mysql_install_db. Copied from startup.sh, then updated to include correct binary or script to use depending on version
MID_AND_OPT=""; START_OPT=""
if [ "$(${BIN} --version | grep -oe '5\.[1567]' | head -n1)" == "5.7" ]; then
  if [[ ! `${BIN}  --version | grep -oe '5\.[1567]\.[0-5]'` ]]; then
    MID_AND_OPT="${BIN} --initialize-insecure"
  else
    MID_AND_OPT="${BIN} --insecure"
  fi
  START_OPT="--core-file"
elif [ "$(${BIN} --version | grep -oe '5\.[1567]' | head -n1)" == "5.6" ]; then
  if [ -r ${MYBASE}/scripts/mysql_install_db ]; then
    MID_AND_OPT="${MYBASE}/scripts/mysql_install_db --force --no-defaults"
    START_OPT="--core-file"
  else
    echoit "Something is wrong: mysqld version was detected as 5.6, yet ${MYBASE}/scripts/mysql_install_db does not exist, or is not readable by this script!"
    exit 1
  fi
elif [ "$(${BIN} --version | grep -oe '5\.[1567]' | head -n1)" == "5.5" ]; then
  if [ -r ${MYBASE}/scripts/mysql_install_db ]; then
    MID_AND_OPT="${MYBASE}/scripts/mysql_install_db --force --no-defaults"
    START_OPT="--core"
  else
    echoit "Something is wrong: mysqld version was detected as 5.6, yet ${MYBASE}/scripts/mysql_install_db does not exist, or is not readable by this script!"
    exit 1
  fi
else
  if [ -r ${MYBASE}/scripts/mysql_install_db ]; then
    echoit "WARNING: mysqld version detection failed. This is likely caused by using this script with a non-supported (only MS and PS are supported currently for versions 5.5, 5.6 and 5.7) distribution or version of mysqld. Please expand this script to handle. This scipt will try and continue, but this may fail."
    MID_AND_OPT="${MYBASE}/scripts/mysql_install_db"
    START_OPT="--core-file"
  else
    echoit "Something is wrong: ${MYBASE}/scripts/mysql_install_db does not exist, or is not readable by this script! mysqld version detected failed also! This is likely caused by using this script with a non-supported (only MS and PS are supported currently for versions 5.5, 5.6 and 5.7) distribution or version of mysqld. Please expand this script to handle. This scipt will try and continue, but this may fail."
    exit 1
  fi
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
    if [ "$(${BIN} --version | grep -oe '5\.[1567]' | head -n1)" != "5.7" ]; then  # For 5.7, the data directory should be empty
      mkdir ${WORKDIR}/${j}
    fi
    ${MID_AND_OPT} --basedir=${MYBASE} --datadir=${WORKDIR}/${j} --user=${MYUSER} > ${WORKDIR}/${j}_mysql_install_db.out 2>&1
    CMD="bash -c \"set -o pipefail; ${BIN} ${MYEXTRA} ${START_OPT} --basedir=${MYBASE} --datadir=${WORKDIR}/${j} --port=${MYPORT}
         --pid-file=${WORKDIR}/${j}_pid.pid --log-error=${WORKDIR}/${j}_error.log.out --socket=${WORKDIR}/${j}_socket.sock --user=${MYUSER}\""
    eval $CMD > ${WORKDIR}/${j}_mysqld.out 2>&1 &
    PIDV="$!"
    MYSQLD+=(${PIDV})
  done
  for j in `seq 1 ${i}`;do
    x=0
    ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1
    CHECK=$?
    while [[ $CHECK != 0 ]]; do
      ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1
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
    ## Below two lines is for pquery testing
    #export LD_LIBRARY_PATH=${MYBASE}/lib
    #$(cd `dirname $0` && pwd)/pquery/pquery --infile=${TRIAL}.out_out --database=test --threads=5 --user=root --socket=${WORKDIR}/${j}_socket.sock > ${WORKDIR}/script_sql_out_${j} 2>&1 &
    echoit "Starting ${CLIENT_THREADS} client threads against mysqld # ${j}..."
    for (( thread=1; thread<=${CLIENT_THREADS}; thread++ )); do
      ${MYBASE}/bin/mysql -uroot --socket=${WORKDIR}/${j}_socket.sock -f < ${SQLFILE} > multi.$thread 2>&1 &
      PID="$!"
      MYSQLC+=($PID)
    done
    # Check if mysqld process crashed immediately
    if ! ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
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
        if ! ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
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
    if ! ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
      echoit "[!] Server crash/shutdown found: Check ${WORKDIR}/${j}_error.log.out for more info"
      TO_EXIT=1
    fi
  done
  # Shutdown mysqld processes
  for j in `seq 1 ${i}`;do
    echoit "Shutting down mysqld #${j}..."
    ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock shutdown > /dev/null 2>&1 &
  done
  sleep ${AFTER_SHUTDOWN_DELAY}
  # Check for shutdown issues
  TO_EXIT=0
  for j in `seq 1 ${i}`;do
    if ${MYBASE}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
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
