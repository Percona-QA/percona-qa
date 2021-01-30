#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Updated by Roel Van de Paar, Percona LLC

# Start this script from within the base directory which contains ./bin/mysqld[-debug]

# User configurable variables
WORKDIR="/dev/shm"                               ## Working directory ("/dev/shm" preferred)
SQLFILE="./in.sql"                               ## SQL Input file
MYEXTRA="--event-scheduler=ON"                   ## MYEXTRA: Extra --options required for msyqld (may not be required)
#MYEXTRA="--event-scheduler=ON --max_allowed_packet=33554432 --maximum-bulk_insert_buffer_size=1M --maximum-join_buffer_size=1M --maximum-max_heap_table_size=1M --maximum-max_join_size=1M --maximum-myisam_max_sort_file_size=1M --maximum-myisam_mmap_size=1M --maximum-myisam_sort_buffer_size=1M --maximum-optimizer_trace_max_mem_size=1M --maximum-preload_buffer_size=1M --maximum-query_alloc_block_size=1M --maximum-query_prealloc_size=1M --maximum-range_alloc_block_size=1M --maximum-read_buffer_size=1M --maximum-read_rnd_buffer_size=1M --maximum-sort_buffer_size=1M --maximum-tmp_table_size=1M --maximum-transaction_alloc_block_size=1M --maximum-transaction_prealloc_size=1M --log-output=none --sql_mode=ONLY_FULL_GROUP_BY --innodb_file_per_table=1 --innodb_flush_method=O_DIRECT --innodb_lock_schedule_algorithm=fcfs --innodb_stats_persistent=off --loose-idle_write_transaction_timeout=0 --loose-idle_transaction_timeout=0 --loose-idle_readonly_transaction_timeout=0 --connect_timeout=60 --interactive_timeout=28800 --slave_net_timeout=60 --net_read_timeout=30 --net_write_timeout=60 --loose-table_lock_wait_timeout=50 --wait_timeout=28800 --lock-wait-timeout=86400 --innodb-lock-wait-timeout=50 --log_output=FILE --log-bin --log_bin_trust_function_creators=1 --loose-max-statement-time=30 --loose-debug_assert_on_not_freed_memory=0 --innodb-buffer-pool-size=256M --innodb_use_native_aio=0"
#MYEXTRA=" --no-defaults"
# --plugin-load=tokudb=ha_tokudb.so --tokudb-check-jemalloc=0 --init-file=/home/roel/mariadb-qa/plugins_57.sql --binlog-group-commit-sync-delay=2047 "
SERVER_THREADS=(2 10 20 30 40 50)                 ## Number of server threads (x mysqld's). This is a sequence: (10 20) means: first 10, then 20 server if no crash was observed
CLIENT_THREADS=1                                  ## Number of client threads (y threads) which will execute the SQLFILE input file against each mysqld
AFTER_SHUTDOWN_DELAY=60                           ## Wait this many seconds for mysqld to shutdown properly. If it does not shutdown within the allotted time, an error shows

# Internal variables
MYUSER=$(whoami)
MYPORT=$[20000 + $RANDOM % 9999 + 1]
DATADIR=`date +'%s'`

# Reference functions
echoit(){ echo "[$(date +'%T')] $1"; }
echoito(){ echo -ne "[$(date +'%T')] $1\r"; }  # Used for on-screen updating of text

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
#INIT_OPT="--no-defaults --initialize-insecure"  # Compatible with     5.7,8.0 (mysqld init)
INIT_OPT="--no-defaults --force --auth-root-authentication-method=normal"  # MD
INIT_TOOL="${BIN}"                # Compatible with     5.7,8.0 (mysqld init), changed to MID later if version <=5.6
VERSION_INFO=$(${BIN} --version | grep -oe '[58]\.[01567]' | head -n1)
if [ "${VERSION_INFO}" == "5.1" -o "${VERSION_INFO}" == "5.5" -o "${VERSION_INFO}" == "5.6" ]; then
  if [ "${MID}" == "" ]; then
    echo "Assert: Version was detected as ${VERSION_INFO}, yet ./scripts/mysql_install_db nor ./bin/mysql_install_db is present!"
    exit 1
  fi
  INIT_TOOL="${MID}"
  INIT_OPT="--no-defaults --force"
  START_OPT="--core"
elif [ "${VERSION_INFO}" != "5.7" -a "${VERSION_INFO}" != "8.0" ]; then
  echo "WARNING: mysqld (${BIN}) version detection failed. This is likely caused by using this script with a non-supported distribution or version of mysqld. Please expand this script to handle (which shoud be easy to do). Even so, the scipt will now try and continue as-is, but this may fail."
fi

# Run SQL file from reducer<trial>.sh
for i in ${SERVER_THREADS[@]};do
  # Start multiple mysqld service
  SERVER_COUNT=0
  MYSQLD=()
  for j in `seq 1 ${i}`;do
    SERVER_COUNT=$[ ${SERVER_COUNT} + 1 ];
    echoito "Starting mysqld #${SERVER_COUNT}..."
    MYPORT=$[ ${MYPORT} + 1 ]
    mkdir ${WORKDIR}/${j} 2>/dev/null
    $INIT_TOOL --no-defaults ${INIT_OPT} --basedir=${PWD} --datadir=${WORKDIR}/${j} > ${WORKDIR}/${j}_mysql_install_db.out 2>&1
    CMD="bash -c \"set -o pipefail; ${BIN} ${MYEXTRA} ${START_OPT} --basedir=${PWD} --datadir=${WORKDIR}/${j} --port=${MYPORT}
         --pid-file=${WORKDIR}/${j}_pid.pid --log-error=${WORKDIR}/${j}_error.log.out --socket=${WORKDIR}/${j}_socket.sock --user=${MYUSER}\""
    eval $CMD > ${WORKDIR}/${j}_mysqld.out 2>&1 &
    PIDV="$!"
    MYSQLD+=(${PIDV})
    echoit "Started mysqld #${SERVER_COUNT} with PID ${MYSQLD[j-1]}"
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
  MYSQLC=()
  for j in `seq 1 ${i}`;do
    echoit "Starting ${CLIENT_THREADS} client threads against mysqld #${j}..."
    ## The following line is for pquery testing (and remark entire for_do_done loop)
    #$(cd `dirname $0` && pwd)/pquery/pquery --infile=${TRIAL}.out_out --database=test --threads=${CLIENT_THREADS} --user=root --socket=${WORKDIR}/${j}_socket.sock > ${WORKDIR}/${j}_pquery.out 2>&1 &
    for (( thread=1; thread<=${CLIENT_THREADS}; thread++ )); do
      ${PWD}/bin/mysql -uroot --socket=${WORKDIR}/${j}_socket.sock -f < ${SQLFILE} > ${WORKDIR}/${j}_client-$thread.out 2>&1 &
      PID="$!"
      MYSQLC+=($PID)
    done
    # Check if mysqld process crashed immediately
    if ! ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
      echoit "[!] Server crash/shutdown found : Check ${WORKDIR}/${j}_error.log.out for more info. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    fi
  done
  sleep 1  # Avoids last client not having started yet
  # Check if mysql client finished
  for k in "${MYSQLC[@]}"; do
    while [[ ( -d /proc/$k ) && ( -z `grep zombie /proc/$k/status` ) ]]; do
      # Check mysqld processes are still alive while waiting for client processes to finish
      for j in `seq 1 ${i}`;do
        if ! ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
          echoit "[!] Server crash/shutdown found: Check ${WORKDIR}/${j}_error.log.out for more info. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
          exit 1
        fi
      done
    done
  done
  # Check mysqld processes are still alive after client processes are done
  for j in `seq 1 ${i}`;do
    if ! ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1; then
      echoit "[!] Server crash/shutdown found: Check ${WORKDIR}/${j}_error.log.out for more info. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    fi
  done
  # Shutdown mysqld processes
  for j in `seq 1 ${i}`;do
    echoit "Shutting down mysqld #${j}..."
    timeout --signal=9 ${AFTER_SHUTDOWN_DELAY}s ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock shutdown > /dev/null 2>&1
    if [ $? -eq 137 ]; then  # Timeout was activated after ${AFTER_SHUTDOWN_DELAY} seconds, highly likely indicating a hang
      echoit "[!] Potential server hang found: mysqld #{j} has not shutdown in ${AFTER_SHUTDOWN_DELAY} seconds. Check gdb --pid=${MYSQLD[j-1]}. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    fi
  done
  # Check for shutdown issues
  for j in `seq 1 ${i}`;do
    # Check for shutdown failure (mysqld still responding to mysqladmin pings)
    PING=
    timeout --signal=9 10s ${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping > /dev/null 2>&1
${PWD}/bin/mysqladmin -uroot -S${WORKDIR}/${j}_socket.sock ping
    PING=$?
echo $PING
    if [ $PING -eq 137 ]; then
      echoit "[!] Potential server hang found: a mysqladmin ping to mysqld #${j} did not complete in 10 sconds. Check gdb --pid=${MYSQLD[j-1]} for more info. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    elif [ $PING -eq 0 ]; then
      echoit "[!] Server hang found: mysqld #${j} has not shutdown in 60 seconds and is still responding to mysqladmin ping. Check gdb --pid=${MYSQLD[j-1]} for more info. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    elif [ $PING -ne 1 ]; then
      echoit "[!] Unknown issue detected: a mysqladmin ping to mysqld #${j} returned exit status $PING, which is unkwnon to this script. Please research this code $PING and the current status of mysqld with gdb --pid=${MYSQLD[j-1]} for more info, then please update this script so it can handle this state. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    fi
    # Check for core dump
    if [ $(ls ${WORKDIR}/${j}/*core* 2>/dev/null | grep -vi "no such file or directory" | wc -l) -gt 0 ]; then
      echoit "[!] Server crash found: mysqld #${j} has generated a core dump. Check ${WORKDIR}/${j}_error.log.out and $(ls -l ${WORKDIR}/${j}/*core* | tr '\n' ' ') for more info. Leaving state as-is and terminating. Consider using mariadb-qa/kill_all_procs.sh to cleanup after your research is done."
      exit 1
    fi
  done
  for j in `seq 1 ${i}`;do
    echo "Checking PID ${MYSQLD[${i}]}"
  done
  kill -9 `printf '%s ' "${MYSQLD[@]}"` 2>/dev/null  # For safety, though processes should be gone. Redirected stderr to /dev/null as otherwise 'multirun_mysqld.sh: line ___: kill: (_____) - No such process' errors would show.
  if [ ${SERVER_THREADS[@]:(-1)} -ne ${i} ] ; then
   echoit "Did not find server crash with ${i} mysqld processes. Restarting crash test with next set of mysqld processes."
   rm -Rf ${WORKDIR}/*
  fi
done
