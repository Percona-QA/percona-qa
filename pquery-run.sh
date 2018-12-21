#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Updated by Ramesh Sivaraman, Percona LLC

# ========================================= User configurable variables ==========================================================
# Note: if an option is passed to this script, it will use that option as the configuration file instead, for example ./pquery-run.sh pquery-run-ps.conf
CONFIGURATION_FILE=pquery-run.conf  # Do not use any path specifiers, the .conf file should be in the same path as pquery-run.sh
#CONFIGURATION_FILE=pquery-run-RocksDB.conf  # RocksDB testing

# ========================================= Improvement ideas ====================================================================
# * SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=0 (These likely include some of the 'SIGKILL' issues - no core but terminated)
# * SQL hashing s/t2/t1/, hex values "0x"
# * Full MTR grammar on one-liners
# * Interleave all statements with another that is likely to cause issues, for example "USE mysql"

# ========================================= MAIN CODE ============================================================================
# Internal variables: DO NOT CHANGE!
RANDOM=`date +%s%N | cut -b14-19`; RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')
SCRIPT_AND_PATH=$(readlink -f $0); SCRIPT=$(echo ${SCRIPT_AND_PATH} | sed 's|.*/||'); SCRIPT_PWD=$(cd `dirname $0` && pwd)
WORKDIRACTIVE=0; SAVED=0; TRIAL=0; MYSQLD_START_TIMEOUT=60; TIMEOUT_REACHED=0; STOREANYWAY=0

# Set ASAN coredump options
# https://github.com/google/sanitizers/wiki/SanitizerCommonFlags
# https://github.com/google/sanitizers/wiki/AddressSanitizerFlags
export ASAN_OPTIONS=quarantine_size_mb=512:atexit=true:detect_invalid_pointer_pairs=1:dump_instruction_bytes=true:abort_on_error=1  # This used to have disable_core=0 (now disable_coredump=0 ?) - TODO: check optimal setting

# Read configuration
if [ "$1" != "" ]; then CONFIGURATION_FILE=$1; fi
if [ ! -r ${SCRIPT_PWD}/${CONFIGURATION_FILE} ]; then echo "Assert: the confiruation file ${SCRIPT_PWD}/${CONFIGURATION_FILE} cannot be read!"; exit 1; fi
source ${SCRIPT_PWD}/${CONFIGURATION_FILE}

# Safety checks: ensure variables are correctly set to avoid rm -Rf issues (if not set correctly, it was likely due to altering internal variables at the top of this file)
if [ "${WORKDIR}" == "/sd[a-z][/]" ]; then echo "Assert! \$WORKDIR == '${WORKDIR}' - is it missing the \$RANDOMD suffix?"; exit 1; fi
if [ "${RUNDIR}" == "/dev/shm[/]" ]; then echo "Assert! \$RUNDIR == '${RUNDIR}' - is it missing the \$RANDOMD suffix?"; exit 1; fi
if [ "$(echo ${RANDOMD} | sed 's|[0-9]|/|g')" != "//////" ]; then echo "Assert! \$RANDOMD == '${RANDOMD}'. This looks incorrect - it should be 6 numbers exactly"; exit 1; fi
if [ "${SKIPCHECKDIRS}" == "" ]; then  # Used in/by pquery-reach.sh TODO: find a better way then hacking to avoid these checks. Check; why do they fail when called from pquery-reach.sh?
  if [ "$(echo ${WORKDIR} | grep -oi "$RANDOMD" | head -n1)" != "${RANDOMD}" ]; then echo "Assert! \$WORKDIR == '${WORKDIR}' - is it missing the \$RANDOMD suffix?"; exit 1; fi
  if [ "$(echo ${RUNDIR}  | grep -oi "$RANDOMD" | head -n1)" != "${RANDOMD}" ]; then echo "Assert! \$WORKDIR == '${WORKDIR}' - is it missing the \$RANDOMD suffix?"; exit 1; fi
fi

# Other safety checks
if [ "$(echo ${PQUERY_BIN} | sed 's|\(^/pquery\)|\1|')" == "/pquery" ]; then echo "Assert! \$PQUERY_BIN == '${PQUERY_BIN}' - is it missing the \$SCRIPT_PWD prefix?"; exit 1; fi
if [ ! -r ${PQUERY_BIN} ]; then echo "${PQUERY_BIN} specified in the configuration file used (${SCRIPT_PWD}/${CONFIGURATION_FILE}) cannot be found/read"; exit 1; fi
if [ ! -r ${OPTIONS_INFILE} ]; then echo "${OPTIONS_INFILE} specified in the configuration file used (${SCRIPT_PWD}/${CONFIGURATION_FILE}) cannot be found/read"; exit 1; fi

# Try and raise ulimit for user processes (see setup_server.sh for how to set correct soft/hard nproc settings in limits.conf)
ulimit -u 7000

# Check input file (when generator is not used)
if [ ${USE_GENERATOR_INSTEAD_OF_INFILE} -ne 1 -a ! -r ${INFILE} ]; then
  echo "Assert! \$INFILE (${INFILE}) cannot be read? Check file existence and privileges!"
  exit 1
fi

# Output function
echoit(){
  echo "[$(date +'%T')] [$SAVED] $1"
  if [ ${WORKDIRACTIVE} -eq 1 ]; then echo "[$(date +'%T')] [$SAVED] $1" >> /${WORKDIR}/pquery-run.log; fi
}

# Find mysqld binary
if [ -r ${BASEDIR}/bin/mysqld ]; then
  BIN=${BASEDIR}/bin/mysqld
else
  # Check if this is a debug build by checking if debug string is present in dirname
  if [[ ${BASEDIR} = *debug* ]]; then
    if [ -r ${BASEDIR}/bin/mysqld-debug ]; then
      BIN=${BASEDIR}/bin/mysqld-debug
    else
      echoit "Assert: there is no (script readable) mysqld binary at ${BASEDIR}/bin/mysqld[-debug] ?"
      exit 1
    fi
  else
    echoit "Assert: there is no (script readable) mysqld binary at ${BASEDIR}/bin/mysqld ?"
    exit 1
  fi
fi

# JEMALLOC for PS/TokuDB
PSORNOT1=$(${BIN} --version | grep -oi 'Percona' | sed 's|p|P|' | head -n1)
PSORNOT2=$(${BIN} --version | grep -oi '5.7.[0-9]\+-[0-9]' | cut -f2 -d'-' | head -n1); if [ "${PSORNOT2}" == "" ]; then PSORNOT2=0; fi
if [ ${SKIP_JEMALLOC_FOR_PS} -ne 1 ]; then
  if [ "${PSORNOT1}" == "Percona" ] || [ ${PSORNOT2} -ge 1 ]; then
    if [ -r `sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
      export LD_PRELOAD=`sudo find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
    else
      echoit "Assert! Binary (${BIN} reported itself as Percona Server, yet jemalloc was not found, please install it!";
      echoit "For Centos7 you can do this by:  sudo yum -y install epel-release; sudo yum -y install jemalloc;"
      echoit "For Ubuntu you can do this by: sudo apt-get install libjemalloc-dev;"
      exit 1;
    fi
  fi
else
  if [ "${PSORNOT1}" == "Percona" ] || [ ${PSORNOT2} -ge 1 ]; then
    echoit "*** IMPORTANT WARNING ***: SKIP_JEMALLOC_FOR_PS was set to 1, and thus JEMALLOC will not be LD_PRELOAD'ed. However, the mysqld binary (${BIN}) reports itself as Percona Server. If you are going to test TokuDB, JEMALLOC should be LD_PRELOAD'ed. If not testing TokuDB, then this warning can be safely ignored."
  fi
fi

#Sanity check for PXB Crash testing run
if [[ ${PXB_CRASH_RUN} -eq 1 ]]; then
  echoit "MODE: Percona Xtrabackup crash test run"
  if [[ ! -d ${PXB_BASEDIR} ]]; then
    echoit "Assert: $PXB_BASEDIR does not exist. Terminating!"
    exit 1
  fi
fi

# Automatic variable adjustments
if [ "$1" == "pxc" -o "$2" == "pxc" -o "$1" == "PXC" -o "$2" == "PXC" ]; then PXC=1; fi  # Check if this is a a PXC run as indicated by first or second option to this script
if [ "$(whoami)" == "root" ]; then MYEXTRA="--user=root ${MYEXTRA}"; fi
if [ ${PXC_CLUSTER_RUN} -eq 1 ]; then
  echoit "As PXC_CLUSTER_RUN=1, this script is auto-assuming this is a PXC run and will set PXC=1"
  PXC=1
fi
if [ ${GRP_RPL_CLUSTER_RUN} -eq 1 ]; then
  echoit "As GRP_RPL_CLUSTER_RUN=1, this script is auto-assuming this is a Group Replication run and will set GRP_RPL=1"
  GRP_RPL=1
fi
if [ ${PXC} -eq 1 ]; then
  if [ ${QUERIES_PER_THREAD} -lt 2147483647 ]; then  # Starting up a cluster takes more time, so don't rotate too quickly
    echoit "Note: As this is a PXC=1 run, and QUERIES_PER_THREAD was set to only ${QUERIES_PER_THREAD}, this script is setting the queries per thread to the required minimum of 2147483647 for this run."
    QUERIES_PER_THREAD=2147483647  # Max int
  fi
  if [ ${PQUERY_RUN_TIMEOUT} -lt 120 ]; then  # Starting up a cluster takes more time, so don't rotate too quickly
    echoit "Note: As this is a PXC=1 run, and PQUERY_RUN_TIMEOUT was set to only ${PQUERY_RUN_TIMEOUT}, this script is setting the timeout to the required minimum of 120 for this run."
    PQUERY_RUN_TIMEOUT=120
  fi
  ADD_RANDOM_OPTIONS=0
  ADD_RANDOM_TOKUDB_OPTIONS=0
  ADD_RANDOM_ROCKSDB_OPTIONS=0
  GRP_RPL=0
  GRP_RPL_CLUSTER_RUN=0
fi

if [ ${GRP_RPL} -eq 1 ]; then
  if [ ${QUERIES_PER_THREAD} -lt 2147483647 ]; then  # Starting up a cluster takes more time, so don't rotate too quickly
    echoit "Note: As this is a GRP_RPL=1 run, and QUERIES_PER_THREAD was set to only ${QUERIES_PER_THREAD}, this script is setting the queries per thread to the required minimum of 2147483647 for this run."
    QUERIES_PER_THREAD=2147483647  # Max int
  fi
  if [ ${PQUERY_RUN_TIMEOUT} -lt 120 ]; then  # Starting up a cluster takes more time, so don't rotate too quickly
    echoit "Note: As this is a GRP_RPL=1 run, and PQUERY_RUN_TIMEOUT was set to only ${PQUERY_RUN_TIMEOUT}, this script is setting the timeout to the required minimum of 120 for this run."
    PQUERY_RUN_TIMEOUT=120
  fi
  ADD_RANDOM_TOKUDB_OPTIONS=0
  ADD_RANDOM_ROCKSDB_OPTIONS=0
  PXC=0
  PXC_CLUSTER_RUN=0
fi

if [ ${QUERY_DURATION_TESTING} -eq 1 ]; then echoit "MODE: Query Duration Testing"; fi
if [ ${QUERY_DURATION_TESTING} -ne 1 -a ${QUERY_CORRECTNESS_TESTING} -ne 1 -a ${CRASH_RECOVERY_TESTING} -ne 1 ]; then
  if [ ${VALGRIND_RUN} -eq 1 ]; then
    if [ ${THREADS} -eq 1 ]; then
      echoit "MODE: Single threaded Valgrind pquery testing"
    else
      echoit "MODE: Multi threaded Valgrind pquery testing"
    fi
  else
    if [ ${THREADS} -eq 1 ]; then
      echoit "MODE: Single threaded pquery testing"
    else
      echoit "MODE: Multi threaded pquery testing"
    fi
  fi
fi
if [ ${THREADS} -gt 1 ]; then  # We may want to drop this to 20 seconds required?
  if [ ${PQUERY_RUN_TIMEOUT} -lt 30 ]; then
    echoit "Note: As this is a multi-threaded run, and PQUERY_RUN_TIMEOUT was set to only ${PQUERY_RUN_TIMEOUT}, this script is setting the timeout to the required minimum of 30 for this run."
    PQUERY_RUN_TIMEOUT=30
  fi
  if [ ${QUERY_DURATION_TESTING} -eq 1 ]; then
    echoit "Note: As this is a QUERY_DURATION_TESTING=1 run, and THREADS was set to ${THREADS}, this script is setting the number of threads to the required setting of 1 thread for this run."
    THREADS=1
  fi
fi
if [ ${CRASH_RECOVERY_TESTING} -eq 1 ]; then
  echoit "MODE: Creash Recovery Testing"
  INFILE=$CRASH_RECOVERY_INFILE
  if [ -a ${QUERY_DURATION_TESTING} -eq 1]; then
    echoit "CRASH_RECOVERY_TESTING and QUERY_DURATION_TESTING cannot be both active at the same time due to parsing limitations. This is the case. Please disable one of them."
    exit 1
  fi
  if [ ${QUERY_CORRECTNESS_TESTING} -eq 1]; then
    echoit "CRASH_RECOVERY_TESTING and QUERY_CORRECTNESS_TESTING cannot be both active at the same time due to parsing limitations. This is the case. Please disable one of them."
    exit 1
  fi
  if [ ${THREADS} -lt 50 ]; then
    echoit "Note: As this is a CRASH_RECOVERY_TESTING=1 run, and THREADS was set to only ${THREADS}, this script is setting the number of threads to the required minimum of 50 for this run."
    THREADS=50
  fi
  if [ ${PQUERY_RUN_TIMEOUT} -lt 30 ]; then
    echoit "Note: As this is a CRASH_RECOVERY_TESTING=1 run, and PQUERY_RUN_TIMEOUT was set to only ${PQUERY_RUN_TIMEOUT}, this script is setting the timeout to the required minimum of 30 for this run."
    PQUERY_RUN_TIMEOUT=30
  fi
fi
if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
  echoit "MODE: Query Correctness Testing"
  if [ ${QUERY_DURATION_TESTING} -eq 1 ]; then
    echoit "QUERY_CORRECTNESS_TESTING and QUERY_DURATION_TESTING cannot be both active at the same time due to parsing limitations. This is the case. Please disable one of them."
    exit 1
  fi
  if [ ${THREADS} -ne 1 ]; then
    echoit "Note: As this is a QUERY_CORRECTNESS_TESTING=1 run, and THREADS was set to ${THREADS}, this script is setting the number of threads to the required setting of 1 thread for this run."
    THREADS=1
  fi
fi
if [ ${USE_GENERATOR_INSTEAD_OF_INFILE} -eq 1 -a ${STORE_COPY_OF_INFILE} -eq 1 ]; then
  echoit "Note: as the SQL Generator will be used instead of an input file (and as such there is more then one inputfile), STORE_COPY_OF_INFILE has automatically been set to 0."
  STORE_COPY_OF_INFILE=0
fi
if [ ${VALGRIND_RUN} -eq 1 ]; then
  echoit "Note: As this is a VALGRIND_RUN=1 run, this script is increasing MYSQLD_START_TIMEOUT (${MYSQLD_START_TIMEOUT}) by 240 seconds because Valgrind is very slow in starting up mysqld."
  MYSQLD_START_TIMEOUT=$[ ${MYSQLD_START_TIMEOUT} + 240 ]
  if [ ${MYSQLD_START_TIMEOUT} -lt 300 ]; then
    echoit "Note: As this is a VALGRIND_RUN=1 run, and MYSQLD_START_TIMEOUT was set to only ${MYSQLD_START_TIMEOUT}), this script is setting the timeout to the required minimum of 300 for this run."
    MYSQLD_START_TIMEOUT=300
  fi
  echoit "Note: As this is a VALGRIND_RUN=1 run, this script is increasing PQUERY_RUN_TIMEOUT (${PQUERY_RUN_TIMEOUT}) by 180 seconds because Valgrind is very slow in processing SQL."
  PQUERY_RUN_TIMEOUT=$[ ${PQUERY_RUN_TIMEOUT} + 180 ]
fi

# Trap ctrl-c
trap ctrl-c SIGINT

ctrl-c(){
  echoit "CTRL+C Was pressed. Attempting to terminate running processes..."
  KILL_PIDS1=`ps -ef | grep "$RANDOMD" | grep -v "grep" | awk '{print $2}' | tr '\n' ' '`
  KILL_PIDS2=
  if [ ${USE_GENERATOR_INSTEAD_OF_INFILE} -eq 1 ]; then
    KILL_PIDS2=`ps -ef | grep generator | grep -v "grep" | awk '{print $2}' | tr '\n' ' '`
  fi
  KILL_PIDS="${KILL_PIDS1} ${KILL_PIDS2}"
  if [ "${KILL_PIDS}" != "" ]; then
    echoit "Terminating the following PID's: ${KILL_PIDS}"
    kill -9 ${KILL_PIDS} >/dev/null 2>&1
  fi
  if [ -d ${RUNDIR}/${TRIAL}/ ]; then
    echoit "Done. Moving the trial $0 was currently working on to workdir as ${WORKDIR}/${TRIAL}/..."
    mv ${RUNDIR}/${TRIAL}/ ${WORKDIR}/ 2>&1 | tee -a /${WORKDIR}/pquery-run.log
  fi
  if [ $USE_GENERATOR_INSTEAD_OF_INFILE -eq 1 ]; then
    echoit "Attempting to cleanup generator temporary files..."
    rm -f ${SCRIPT_PWD}/generator/generator${RANDOMD}.sh
    rm -f ${SCRIPT_PWD}/generator/out${RANDOMD}*.sql
  fi
  if [ $PMM -eq 1 ]; then
    echoit "Attempting to cleanup PMM client services..."
    sudo pmm-admin remove --all > /dev/null
  fi
  echoit "Attempting to cleanup the pquery rundir ${RUNDIR}..."
  rm -Rf ${RUNDIR}
  if [ $SAVED -eq 0 -a ${SAVE_SQL} -eq 0 ]; then
    echoit "There were no coredumps saved, and SAVE_SQL=0, so the workdir can be safely deleted. Doing so..."
    WORKDIRACTIVE=0
    rm -Rf ${WORKDIR}
  else
    echoit "The results of this run can be found in the workdir ${WORKDIR}..."
  fi
  echoit "Done. Terminating pquery-run.sh with exit code 2..."
  exit 2
}

savetrial(){  # Only call this if you definitely want to save a trial
  echoit "Copying rundir from ${RUNDIR}/${TRIAL} to ${WORKDIR}/${TRIAL}"
  mv ${RUNDIR}/${TRIAL}/ ${WORKDIR}/ 2>&1 | tee -a /${WORKDIR}/pquery-run.log
  if [ $PMM_CLEAN_TRIAL -eq 1 ];then
    echoit "Removing mysql instance (pq${RANDOMD}-${TRIAL}) from pmm-admin"
    sudo pmm-admin remove mysql pq${RANDOMD}-${TRIAL} > /dev/null
  fi
  SAVED=$[ $SAVED + 1 ]
}

removetrial(){
  echoit "Removing trial rundir ${RUNDIR}/${TRIAL}"
  if [ "${RUNDIR}" != "" -a "${TRIAL}" != "" -a -d ${RUNDIR}/${TRIAL}/ ]; then  # Protection against dangerous rm's
    rm -Rf ${RUNDIR}/${TRIAL}/
  fi
  if [ $PMM_CLEAN_TRIAL -eq 1 ];then
    echoit "Removing mysql instance (pq${RANDOMD}-${TRIAL}) from pmm-admin"
    sudo pmm-admin remove mysql pq${RANDOMD}-${TRIAL} > /dev/null
  fi
}

savesql(){
  echoit "Copying sql trace(s) from ${RUNDIR}/${TRIAL} to ${WORKDIR}/${TRIAL}"
  mkdir ${WORKDIR}/${TRIAL}
  cp ${RUNDIR}/${TRIAL}/*.sql ${WORKDIR}/${TRIAL}/
  rm -Rf ${RUNDIR}/${TRIAL}
  sync; sleep 0.2
  if [ -d ${RUNDIR}/${TRIAL} ]; then
    echoit "Assert: tried to remove ${RUNDIR}/${TRIAL}, but it looks like removal failed. Check what is holding lock? (lsof tool may help)."
    echoit "As this is not necessarily a fatal error (there is likely enough space on ${RUNDIR} to continue working), pquery-run.sh will NOT terminate."
    echoit "However, this looks like a shortcoming in pquery-run.sh (likely in the mysqld termination code) which needs debugging and fixing. Please do."
  fi
}

check_cmd(){
  CMD_PID=$1
  ERROR_MSG=$2
  if [ ${CMD_PID} -ne 0 ]; then echo -e "\nERROR: $ERROR_MSG. Terminating!"; exit 1; fi
}

if [[ $PXC -eq 1 ]];then
  # Creating default my.cnf file
  rm -rf ${BASEDIR}/my.cnf
  echo "[mysqld]" > ${BASEDIR}/my.cnf
  echo "basedir=${BASEDIR}" >> ${BASEDIR}/my.cnf
  echo "wsrep-debug=ON" >> ${BASEDIR}/my.cnf
  echo "innodb_file_per_table" >> ${BASEDIR}/my.cnf
  echo "innodb_autoinc_lock_mode=2" >> ${BASEDIR}/my.cnf
  echo "innodb_locks_unsafe_for_binlog=1" >> ${BASEDIR}/my.cnf
  echo "wsrep-provider=${BASEDIR}/lib/libgalera_smm.so" >> ${BASEDIR}/my.cnf
  echo "wsrep_sst_method=rsync" >> ${BASEDIR}/my.cnf
  echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${BASEDIR}/my.cnf
  echo "wsrep_sst_method=rsync" >> ${BASEDIR}/my.cnf
  echo "core-file" >> ${BASEDIR}/my.cnf
  echo "log-output=none" >> ${BASEDIR}/my.cnf
  echo "wsrep_slave_threads=2" >> ${BASEDIR}/my.cnf
fi
pxc_startup(){
  ADDR="127.0.0.1"
  RPORT=$(( (RANDOM%21 + 10)*1000 ))
  SUSER=root
  SPASS=
  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
    MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
  elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
    MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
  fi

  pxc_startup_chk(){
    ERROR_LOG=$1
    if grep -qi "ERROR. Aborting" $ERROR_LOG ; then
      if grep -qi "TCP.IP port. Address already in use" $ERROR_LOG ; then
        echoit "Assert! The text '[ERROR] Aborting' was found in the error log due to a IP port conflict (the port was already in use)"
        removetrial
      else
        if [ ${PXC_ADD_RANDOM_OPTIONS} -eq 0 ]; then  # Halt for PXC_ADD_RANDOM_OPTIONS=0 runs which have 'ERROR. Aborting' in the error log, as they should not produce errors like these, given that the PXC_MYEXTRA and WSREP_PROVIDER_OPT lists are/should be high-quality/non-faulty
          echoit "Assert! '[ERROR] Aborting' was found in the error log. This is likely an issue with one of the \$PXC_MYEXTRA (${PXC_MYEXTRA}) startup or \$WSREP_PROVIDER_OPT ($WSREP_PROVIDER_OPT) congifuration options. Saving trial for further analysis, and dumping error log here for quick analysis. Please check the output against these variables settings. The respective files for these options (${PXC_WSREP_OPTIONS_INFILE} and ${PXC_WSREP_PROVIDER_OPTIONS_INFILE}) may require editing."
          grep "ERROR" $ERROR_LOG | tee -a /${WORKDIR}/pquery-run.log
          if [ ${PXC_IGNORE_ALL_OPTION_ISSUES} -eq 1 ]; then
            echoit "PXC_IGNORE_ALL_OPTION_ISSUES=1, so irrespective of the assert given, pquery-run.sh will continue running. Please check your option files!"
          else
            savetrial
            echoit "Remember to cleanup/delete the rundir:  rm -Rf ${RUNDIR}"
            exit 1
          fi
        else  # Do not halt for PXC_ADD_RANDOM_OPTIONS=1 runs, they are likely to produce errors like these as PXC_MYEXTRA was randomly changed
          echoit "'[ERROR] Aborting' was found in the error log. This is likely an issue with one of the \$PXC_MYEXTRA (${PXC_MYEXTRA}) startup options. As \$PXC_ADD_RANDOM_OPTIONS=1, this is likely to be encountered given the random addition of mysqld options. Not saving trial. If you see this error for every trial however, set \$PXC_ADD_RANDOM_OPTIONS=0 & try running pquery-run.sh again. If it still fails, it is likely that your base \$MYEXTRA (${MYEXTRA}) setting is faulty."
          grep "ERROR" $ERROR_LOG | tee -a /${WORKDIR}/pquery-run.log
          FAILEDSTARTABORT=1
          break
        fi
      fi
    fi
  }
  for i in `seq 1 3`;do
    RBASE1="$(( RPORT + ( 100 * $i ) ))"
    LADDR1="127.0.0.1:$(( RBASE1 + 8 ))"
	if [ $i -eq 1 ];then
	  WSREP_CLUSTER="gcomm://"
	else
      WSREP_CLUSTER="$WSREP_CLUSTER,gcomm://$LADDR1"
	fi
    if [[ $WITH_KEYRING_VAULT -eq 1 ]]; then
      MYEXTRA_KEYRING="--early-plugin-load=keyring_vault.so --loose-keyring_vault_config=$WORKDIR/vault/keyring_vault_pxc${i}.cnf"
    fi
    if [ "$1" == "startup" ]; then
      node="${WORKDIR}/node${i}.template"
      if [[ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]]; then
        mkdir -p $node
      fi
      WSREP_PROVIDER_OPT=""
    else
      node="${RUNDIR}/${TRIAL}/node${i}"
    fi
    if [ "$1" == "startup" ]; then
      ${MID} --datadir=$node  > ${WORKDIR}/startup_node1.err 2>&1 || exit 1;
    fi
    if [ ${VALGRIND_RUN} -eq 1 ]; then
      VALGRIND_CMD="${VALGRIND_CMD}"
    else
      VALGRIND_CMD=""
    fi

    $VALGRIND_CMD ${BASEDIR}/bin/mysqld --defaults-file=${BASEDIR}/my.cnf \
      $STARTUP_OPTION --datadir=$node \
      --server-id=10${i} $MYEXTRA_KEYRING $MYEXTRA $PXC_MYEXTRA \
      --wsrep_cluster_address=$WSREP_CLUSTER \
      --wsrep_node_incoming_address=$ADDR \
      --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;$WSREP_PROVIDER_OPT" \
      --wsrep_node_address=$ADDR --log-error=$node/node${i}.err \
      --socket=$node/node${i}_socket.sock --port=$RBASE1 > $node/node${i}.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BASEDIR}/bin/mysqladmin -uroot -S$node/node${i}_socket.sock ping > /dev/null 2>&1; then
        break
      fi
      pxc_startup_chk $node/node${i}.err
    done
	if [[ $i -eq 1 ]];then
	  WSREP_CLUSTER="gcomm://$LADDR1"
    fi
  done
  if [ "$1" == "startup" ]; then
    ${BASEDIR}/bin/mysql -uroot -S$node/node${i}_socket.sock -e "create database if not exists test" > /dev/null 2>&1
  fi
}

gr_startup(){
  ADDR="127.0.0.1"
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE="$(( RPORT*1000 ))"
  RBASE1="$(( RBASE + 1 ))"
  RBASE2="$(( RBASE + 2 ))"
  RBASE3="$(( RBASE + 3 ))"
  LADDR1="$ADDR:$(( RBASE + 101 ))"
  LADDR2="$ADDR:$(( RBASE + 102 ))"
  LADDR3="$ADDR:$(( RBASE + 103 ))"

  SUSER=root
  SPASS=

  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
  if [ ${GRP_RPL_CLUSTER_RUN} -eq 1 ]; then
    MYEXTRA="$MYEXTRA --plugin-load=group_replication.so --group_replication_single_primary_mode=OFF"
  else
    MYEXTRA="$MYEXTRA --plugin-load=group_replication.so"
  fi
  if [ "$1" == "startup" ]; then
    node1="${WORKDIR}/node1.template"
    node2="${WORKDIR}/node2.template"
    node3="${WORKDIR}/node3.template"
  else
    node1="${RUNDIR}/${TRIAL}/node1"
    node2="${RUNDIR}/${TRIAL}/node2"
    node3="${RUNDIR}/${TRIAL}/node3"
  fi

  gr_startup_chk(){
    ERROR_LOG=$1
    if grep -qi "ERROR. Aborting" $ERROR_LOG ; then
      if grep -qi "TCP.IP port. Address already in use" $ERROR_LOG ; then
        echoit "Assert! The text '[ERROR] Aborting' was found in the error log due to a IP port conflict (the port was already in use)"
        removetrial
      else
        echoit "Assert! '[ERROR] Aborting' was found in the error log. This is likely an issue with one of the \$MYEXTRA (${MYEXTRA}) startup options. Saving trial for further analysis, and dumping error log here for quick analysis. Please check the output against these variables settings."
        grep "ERROR" $ERROR_LOG | tee -a /${WORKDIR}/pquery-run.log
        savetrial
        echoit "Remember to cleanup/delete the rundir:  rm -Rf ${RUNDIR}"
        exit 1
      fi
    fi
  }

  if [ "$1" == "startup" ]; then
    ${MID} --datadir=$node1  > ${WORKDIR}/startup_node1.err 2>&1 || exit 1;
  fi

  ${BASEDIR}/bin/mysqld --no-defaults \
    --basedir=${BASEDIR} --datadir=$node1 \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \
    --master_info_repository=TABLE --relay_log_info_repository=TABLE \
    --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \
    --binlog_format=ROW --innodb_flush_method=O_DIRECT \
    --core-file --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node1/node1.err \
    --socket=$node1/node1_socket.sock --log-output=none \
    --port=$RBASE1 --transaction_write_set_extraction=XXHASH64 \
    --loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    --loose-group_replication_start_on_boot=off --loose-group_replication_local_address="$LADDR1" \
    --loose-group_replication_group_seeds="$LADDR1,$LADDR2,$LADDR3" \
    --loose-group_replication_bootstrap_group=off --super_read_only=OFF > $node1/node1.err 2>&1 &

  for X in $(seq 0 ${GRP_RPL_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node1/node1_socket.sock ping > /dev/null 2>&1; then
      sleep 2
      if [ "$1" == "startup" ]; then
        ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "SET GLOBAL group_replication_bootstrap_group=ON;START GROUP_REPLICATION;SET GLOBAL group_replication_bootstrap_group=OFF;SELECT SLEEP(10);" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "create database if not exists test" > /dev/null 2>&1
      else
        ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -Bse "SET GLOBAL group_replication_bootstrap_group=ON;START GROUP_REPLICATION;SET GLOBAL group_replication_bootstrap_group=OFF;SELECT SLEEP(5);" > /dev/null 2>&1
      fi
      break
    fi
    gr_startup_chk $node1/node1.err
  done

  if [ "$1" == "startup" ]; then
    ${MID} --datadir=$node2  > ${WORKDIR}/startup_node2.err 2>&1 || exit 1;
  fi

  ${BASEDIR}/bin/mysqld --no-defaults \
    --basedir=${BASEDIR} --datadir=$node2 \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \
    --master_info_repository=TABLE --relay_log_info_repository=TABLE \
    --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \
    --binlog_format=ROW --innodb_flush_method=O_DIRECT \
    --core-file --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node2/node2.err \
    --socket=$node2/node2_socket.sock --log-output=none \
    --port=$RBASE2 --transaction_write_set_extraction=XXHASH64 \
    --loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    --loose-group_replication_start_on_boot=off --loose-group_replication_local_address="$LADDR2" \
    --loose-group_replication_group_seeds="$LADDR1,$LADDR2,$LADDR3" \
    --loose-group_replication_bootstrap_group=off --super_read_only=OFF > $node2/node2.err 2>&1 &

  for X in $(seq 0 ${GRP_RPL_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node2/node2_socket.sock ping > /dev/null 2>&1; then
      sleep 2
      if [ "$1" == "startup" ]; then
        ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "START GROUP_REPLICATION;" > /dev/null 2>&1
      else
        ${BASEDIR}/bin/mysql -uroot -S$node2/node2_socket.sock -Bse "START GROUP_REPLICATION;SELECT SLEEP(5);" > /dev/null 2>&1
      fi
      break
    fi
    gr_startup_chk $node2/node2.err
  done

  if [ "$1" == "startup" ]; then
    ${MID} --datadir=$node3  > ${WORKDIR}/startup_node3.err 2>&1 || exit 1;
  fi

  ${BASEDIR}/bin/mysqld --no-defaults \
    --basedir=${BASEDIR} --datadir=$node3 \
    --innodb_file_per_table $MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \
    --master_info_repository=TABLE --relay_log_info_repository=TABLE \
    --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \
    --binlog_format=ROW --innodb_flush_method=O_DIRECT \
    --core-file --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=$node3/node3.err \
    --socket=$node3/node3_socket.sock --log-output=none \
    --port=$RBASE3 --transaction_write_set_extraction=XXHASH64 \
    --loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
    --loose-group_replication_start_on_boot=off --loose-group_replication_local_address="$LADDR3" \
    --loose-group_replication_group_seeds="$LADDR1,$LADDR2,$LADDR3" \
    --loose-group_replication_bootstrap_group=off --super_read_only=OFF > $node3/node3.err 2>&1 &

  for X in $(seq 0 ${GRP_RPL_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node3/node3_socket.sock ping > /dev/null 2>&1; then
      sleep 2
      if [ "$1" == "startup" ]; then
        ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';" > /dev/null 2>&1
        ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "START GROUP_REPLICATION;" > /dev/null 2>&1
      else
        ${BASEDIR}/bin/mysql -uroot -S$node3/node3_socket.sock -Bse "START GROUP_REPLICATION;SELECT SLEEP(5);" > /dev/null 2>&1
      fi
      break
    fi
    gr_startup_chk $node3/node3.err
  done
}

pquery_test(){
  TRIAL=$[ ${TRIAL} + 1 ]
  echoit "====== TRIAL #${TRIAL} ======"
  echoit "Ensuring there are no relevant servers running..."
  KILLPID=$(ps -ef | grep "${RUNDIR}" | grep -v grep | awk '{print $2}' | tr '\n' ' ')
  (sleep 0.2; kill -9 $KILLPID >/dev/null 2>&1; timeout -k4 -s9 4s wait $KILLPID >/dev/null 2>&1) &
  timeout -k5 -s9 5s wait $KILLDPID >/dev/null 2>&1  # The sleep 0.2 + subsequent wait (cought before the kill) avoids the annoying 'Killed' message from being displayed in the output. Thank you to user 'Foonly' @ forums.whirlpool.net.au
  echoit "Clearing rundir..."
  rm -Rf ${RUNDIR}/*
  if [ ${USE_GENERATOR_INSTEAD_OF_INFILE} -eq 1 ]; then
    echoit "Generating new SQL inputfile using the SQL Generator..."
    SAVEDIR=${PWD}
    cd ${SCRIPT_PWD}/generator/
    if [ ${TRIAL} -eq 1 -o $[ ${TRIAL} % ${GENERATE_NEW_QUERIES_EVERY_X_TRIALS} ] -eq 0 ]; then
      if [ "${RANDOMD}" == "" ]; then
        echoit "Assert: RANDOMD is empty. This should not happen. Terminating."
        exit 1
      fi
      cp generator.sh generator${RANDOMD}.sh
      sed -i "s|^[ \t]*OUTPUT_FILE[ \t]*=.*|OUTPUT_FILE=out${RANDOMD}|" generator${RANDOMD}.sh
      ./generator${RANDOMD}.sh ${QUERIES_PER_GENERATOR_RUN} >/dev/null
      if [ ! -r out${RANDOMD}.sql ]; then
        echoit "Assert: out${RANDOMD}.sql not present in ${PWD} after generator execution! This script left ${PWD}/generator${RANDOMD}.sh in place to check what happened"
        exit 1
      fi
      rm -f generator${RANDOMD}.sh
      if [[ "${MYEXTRA^^}" != *"ROCKSDB"* ]]; then  # If this is not a RocksDB run, exclude RocksDB SE
        sed -i "s|RocksDB|InnoDB|" out${RANDOMD}.sql
      fi
      if [[ "${MYEXTRA^^}" != *"HA_TOKUDB"* ]]; then  # If this is not a TokuDB enabled run, exclude TokuDB SE
        sed -i "s|TokuDB|InnoDB|" out${RANDOMD}.sql
      fi
      if [ ${ADD_INFILE_TO_GENERATED_SQL} -eq 1 ]; then
        cat ${INFILE} >> out${RANDOMD}.sql
      fi
    fi
    INFILE=${PWD}/out${RANDOMD}.sql
    cd ${SAVEDIR}
  fi
  echoit "Generating new trial workdir ${RUNDIR}/${TRIAL}..."
  ISSTARTED=0
  if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
    if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '8\.[0]' | head -n1)" == "8.0" ]; then
      mkdir -p ${RUNDIR}/${TRIAL}/data ${RUNDIR}/${TRIAL}/tmp ${RUNDIR}/${TRIAL}/log  # Cannot create /data/test, /data/mysql in 8.0
    else
      mkdir -p ${RUNDIR}/${TRIAL}/data/test ${RUNDIR}/${TRIAL}/data/mysql ${RUNDIR}/${TRIAL}/tmp ${RUNDIR}/${TRIAL}/log
    fi
    echo 'SELECT 1;' > ${RUNDIR}/${TRIAL}/startup_failure_thread-0.sql  # Add fake file enabling pquery-prep-red.sh/reducer.sh to be used with/for mysqld startup issues
    if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
      echoit "Copying datadir from template for Primary mysqld..."
    else
      echoit "Copying datadir from template..."
    fi
    if [ `ls -l ${WORKDIR}/data.template/* | wc -l` -eq 0 ]; then
      echoit "Assert: ${WORKDIR}/data.template/ is empty? Check ${WORKDIR}/log/mysql_install_db.txt to see if the original template creation worked ok. Terminating."
      echoit "Note that this is can be caused by not having perl-Data-Dumper installed (sudo yum install perl-Data-Dumper), which is required for mysql_install_db."
      exit 1
    fi
    cp -R ${WORKDIR}/data.template/* ${RUNDIR}/${TRIAL}/data 2>&1
    MYEXTRA_SAVE_IT=${MYEXTRA}
    if [ ${ADD_RANDOM_OPTIONS} -eq 1 ]; then  # Add random mysqld --options to MYEXTRA
      OPTIONS_TO_ADD=
      NR_OF_OPTIONS_TO_ADD=$(( RANDOM % MAX_NR_OF_RND_OPTS_TO_ADD + 1 ))
      for X in $(seq 1 ${NR_OF_OPTIONS_TO_ADD}); do
        OPTION_TO_ADD="$(shuf --random-source=/dev/urandom ${OPTIONS_INFILE} | head -n1)"
        if [ "$(echo ${OPTION_TO_ADD} | sed 's| ||g;s|.*query.alloc.block.size=1125899906842624.*||' )" != "" ]; then  # http://bugs.mysql.com/bug.php?id=78238
          OPTIONS_TO_ADD="${OPTIONS_TO_ADD} ${OPTION_TO_ADD}"
        fi
      done
      echoit "ADD_RANDOM_OPTIONS=1: adding mysqld option(s) ${OPTIONS_TO_ADD} to this run's MYEXTRA..."
      MYEXTRA="${MYEXTRA} ${OPTIONS_TO_ADD}"
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        MYEXTRA2="${MYEXTRA2} ${OPTIONS_TO_ADD}"
      fi
    fi
    if [ ${ADD_RANDOM_TOKUDB_OPTIONS} -eq 1 ]; then  # Add random tokudb --options to MYEXTRA
      OPTIONS_TO_ADD=
      NR_OF_OPTIONS_TO_ADD=$(( RANDOM % MAX_NR_OF_RND_OPTS_TO_ADD + 1 ))
      for X in $(seq 1 ${NR_OF_OPTIONS_TO_ADD}); do
        OPTION_TO_ADD=
        OPTION_TO_ADD="$(shuf --random-source=/dev/urandom ${TOKUDB_OPTIONS_INFILE} | head -n1)"
        OPTIONS_TO_ADD="${OPTIONS_TO_ADD} ${OPTION_TO_ADD}"
      done
      echoit "ADD_RANDOM_TOKUDB_OPTIONS=1: adding TokuDB mysqld option(s) ${OPTIONS_TO_ADD} to this run's MYEXTRA..."
      MYEXTRA="${MYEXTRA} ${OPTIONS_TO_ADD}"
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        MYEXTRA2="${MYEXTRA2} ${OPTIONS_TO_ADD}"
      fi
    fi
    if [ "${ADD_RANDOM_ROCKSDB_OPTIONS}" == "" ]; then  # Backwards compatibility for .conf files without this option
      ADD_RANDOM_ROCKSDB_OPTIONS=0
    fi
    if [ ${ADD_RANDOM_ROCKSDB_OPTIONS} -eq 1 ]; then  # Add random rocksdb --options to MYEXTRA
      OPTION_TO_ADD=
      OPTIONS_TO_ADD=
      NR_OF_OPTIONS_TO_ADD=$(( RANDOM % MAX_NR_OF_RND_OPTS_TO_ADD + 1 ))
      for X in $(seq 1 ${NR_OF_OPTIONS_TO_ADD}); do
        OPTION_TO_ADD="$(shuf --random-source=/dev/urandom ${ROCKSDB_OPTIONS_INFILE} | head -n1)"
        OPTIONS_TO_ADD="${OPTIONS_TO_ADD} ${OPTION_TO_ADD}"
      done
      echoit "ADD_RANDOM_ROCKSDB_OPTIONS=1: adding RocksDB mysqld option(s) ${OPTIONS_TO_ADD} to this run's MYEXTRA..."
      MYEXTRA="${MYEXTRA} ${OPTIONS_TO_ADD}"
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        MYEXTRA2="${MYEXTRA2} ${OPTIONS_TO_ADD}"
      fi
    fi
    echo "${MYEXTRA}" | if grep -qi "innodb[_-]log[_-]checksum[_-]algorithm"; then
      # Ensure that mysqld server startup will not fail due to a mismatched checksum algo between the original MID and the changed MYEXTRA options
      rm ${RUNDIR}/${TRIAL}/data/ib_log*
    fi
    PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
    if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
      echoit "Starting Primary mysqld. Error log is stored at ${RUNDIR}/${TRIAL}/log/master.err"
    else
      echoit "Starting mysqld. Error log is stored at ${RUNDIR}/${TRIAL}/log/master.err"
    fi
    if [ ${VALGRIND_RUN} -eq 0 ]; then
      CMD="${BIN} ${MYSAFE} ${MYEXTRA} --basedir=${BASEDIR} --datadir=${RUNDIR}/${TRIAL}/data --tmpdir=${RUNDIR}/${TRIAL}/tmp \
        --core-file --port=$PORT --pid_file=${RUNDIR}/${TRIAL}/pid.pid --socket=${RUNDIR}/${TRIAL}/socket.sock \
        --log-output=none --log-error=${RUNDIR}/${TRIAL}/log/master.err"
    else
      CMD="${VALGRIND_CMD} ${BIN} ${MYSAFE} ${MYEXTRA} --basedir=${BASEDIR} --datadir=${RUNDIR}/${TRIAL}/data --tmpdir=${RUNDIR}/${TRIAL}/tmp \
        --core-file --port=$PORT --pid_file=${RUNDIR}/${TRIAL}/pid.pid --socket=${RUNDIR}/${TRIAL}/socket.sock \
        --log-output=none --log-error=${RUNDIR}/${TRIAL}/log/master.err"
    fi
    $CMD > ${RUNDIR}/${TRIAL}/log/master.err 2>&1 &
    MPID="$!"
    if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
      echoit "Starting Secondary mysqld. Error log is stored at ${RUNDIR}/${TRIAL}/log2/master.err"
      if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '8\.[0]' | head -n1)" == "8.0" ]; then
        mkdir -p ${RUNDIR}/${TRIAL}/data2 ${RUNDIR}/${TRIAL}/tmp2 ${RUNDIR}/${TRIAL}/log2  # Cannot create /data/test, /data/mysql in 8.0
      else
        mkdir -p ${RUNDIR}/${TRIAL}/data2/test ${RUNDIR}/${TRIAL}/data2/mysql ${RUNDIR}/${TRIAL}/tmp2 ${RUNDIR}/${TRIAL}/log2
      fi
      echoit "Copying datadir from template for Secondary mysqld..."
      cp -R ${WORKDIR}/data.template/* ${RUNDIR}/${TRIAL}/data2 2>&1
      PORT2=$[ $PORT + 1 ]
      if [ ${VALGRIND_RUN} -eq 0 ]; then
        CMD2="${BIN} ${MYSAFE} ${MYEXTRA2} --basedir=${BASEDIR} --datadir=${RUNDIR}/${TRIAL}/data2 --tmpdir=${RUNDIR}/${TRIAL}/tmp2 \
          --core-file --port=$PORT2 --pid_file=${RUNDIR}/${TRIAL}/pid2.pid --socket=${RUNDIR}/${TRIAL}/socket2.sock \
          --log-output=none --log-error=${RUNDIR}/${TRIAL}/log2/master.err"
      else
        CMD2="${VALGRIND_CMD} ${BIN} ${MYSAFE} ${MYEXTRA2} --basedir=${BASEDIR} --datadir=${RUNDIR}/${TRIAL}/data2 --tmpdir=${RUNDIR}/${TRIAL}/tmp2 \
          --core-file --port=$PORT2 --pid_file=${RUNDIR}/${TRIAL}/pid2.pid --socket=${RUNDIR}/${TRIAL}/socket2.sock \
          --log-output=none --log-error=${RUNDIR}/${TRIAL}/log2/master.err"
      fi
      $CMD2 > ${RUNDIR}/${TRIAL}/log2/master.err 2>&1 &
      MPID2="$!"
      sleep 1
    fi
    echo "## Good for reproducing mysqld (5.7+) startup issues only (full issues need a data dir, so use mysql_install_db or mysqld --init for those)" > ${RUNDIR}/${TRIAL}/start
    echo "## Another strategy is to activate the data dir copy below, this way the server will be brought up with the same state as it crashed/was shutdown" >> ${RUNDIR}/${TRIAL}/start
    echo "echo '=== Setting up directories...'" >> ${RUNDIR}/${TRIAL}/start
    echo "rm -Rf ${RUNDIR}/${TRIAL}" >> ${RUNDIR}/${TRIAL}/start
    echo "mkdir -p ${RUNDIR}/${TRIAL}/data ${RUNDIR}/${TRIAL}/tmp ${RUNDIR}/${TRIAL}/log" >> ${RUNDIR}/${TRIAL}/start
    echo "#cp -R ./data/* ${RUNDIR}/${TRIAL}/data  # When using this, please also remark the 'Data dir init' below to avoid overwriting the data directory" >> ${RUNDIR}/${TRIAL}/start
    echo "echo '=== Data dir init...'" >> ${RUNDIR}/${TRIAL}/start
    echo "${BIN} --no-defaults --initialize-insecure --basedir=${BASEDIR} --datadir=${RUNDIR}/${TRIAL}/data --tmpdir=${RUNDIR}/${TRIAL}/tmp --core-file --port=$PORT --pid_file=${RUNDIR}/${TRIAL}/pid.pid --socket=${RUNDIR}/${TRIAL}/socket.sock --log-output=none --log-error=${RUNDIR}/${TRIAL}/log/master.err" >> ${RUNDIR}/${TRIAL}/start
    echo "echo '=== Starting mysqld...'" >> ${RUNDIR}/${TRIAL}/start
    echo "${CMD} > ${RUNDIR}/${TRIAL}/log/master.err 2>&1" >> ${RUNDIR}/${TRIAL}/start
    if [ "${MYEXTRA}" != "" ]; then
      echo "# Same startup command, but without MYEXTRA included:" >> ${RUNDIR}/${TRIAL}/start
      echo "#$(echo ${CMD} | sed "s|${MYEXTRA}||") > ${RUNDIR}/${TRIAL}/log/master.err 2>&1" >> ${RUNDIR}/${TRIAL}/start
    fi
    if [ "${MYSAFE}" != "" ]; then
      if [ "${MYEXTRA}" != "" ]; then
        echo "# Same startup command, but without MYEXTRA and MYSAFE included:" >> ${RUNDIR}/${TRIAL}/start
        echo "#$(echo ${CMD} | sed "s|${MYEXTRA}||;s|${MYSAFE}||") > ${RUNDIR}/${TRIAL}/log/master.err 2>&1" >> ${RUNDIR}/${TRIAL}/start
      else
        echo "# Same startup command, but without MYSAFE included (and MYEXTRA was already empty):" >> ${RUNDIR}/${TRIAL}/start
        echo "#$(echo ${CMD} | sed "s|${MYSAFE}||") > ${RUNDIR}/${TRIAL}/log/master.err 2>&1" >> ${RUNDIR}/${TRIAL}/start
      fi
    fi
    chmod +x ${RUNDIR}/${TRIAL}/start
    echo "BASEDIR=$BASEDIR" > ${RUNDIR}/${TRIAL}/start_recovery
	
    echo "${CMD//$RUNDIR/$WORKDIR} --init-file=${WORKDIR}/recovery-user.sql > ${WORKDIR}/${TRIAL}/log/master.err 2>&1 &" >> ${RUNDIR}/${TRIAL}/start_recovery ; chmod +x ${RUNDIR}/${TRIAL}/start_recovery
    # New MYEXTRA/MYSAFE variables pass & VALGRIND run check method as of 2015-07-28 (MYSAFE & MYEXTRA stored in a text file inside the trial dir, VALGRIND file created if used)
    if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
      echo "${MYSAFE} ${MYEXTRA}" > ${RUNDIR}/${TRIAL}/MYEXTRA.left   # When changing this, also search for/edit other '\.left' and '\.right' occurences in this file
      echo "${MYSAFE} ${MYEXTRA2}" > ${RUNDIR}/${TRIAL}/MYEXTRA.right
    else
      echo "${MYSAFE} ${MYEXTRA}" > ${RUNDIR}/${TRIAL}/MYEXTRA
    fi
    echo "${MYINIT}" > ${RUNDIR}/${TRIAL}/MYINIT
    if [ ${VALGRIND_RUN} -eq 1 ]; then
      touch ${RUNDIR}/${TRIAL}/VALGRIND
    fi
    # Restore orignal MYEXTRA for the next trial (MYEXTRA is no longer needed anywhere else. If this changes in the future, relocate this to below the changed code)
    MYEXTRA=${MYEXTRA_SAVE_IT}
    # Give up to x (start timeout) seconds for mysqld to start, but check intelligently for known startup issues like "Error while setting value" for options
    if [ ${VALGRIND_RUN} -eq 0 ]; then
      echoit "Waiting for mysqld (pid: ${MPID}) to fully start..."
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        echoit "Waiting for mysqld (pid: ${MPID2}) to fully start..."
      fi
    else
      echoit "Waiting for mysqld (pid: ${MPID}) to fully start (note this is slow for Valgrind runs, and can easily take 35-90 seconds even on an high end server)..."
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        echoit "Waiting for mysqld (pid: ${MPID2}) to fully start (note this is slow for Valgrind runs, and can easily take 35-90 seconds even on an high end server)..."
      fi
    fi
    BADVALUE=0
    FAILEDSTARTABORT=0
    for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
      sleep 1
      if ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/socket.sock ping > /dev/null 2>&1; then
        if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
          if ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/socket2.sock ping > /dev/null 2>&1; then
            break
          fi
        else
          break
        fi
      fi
      if [ "${MPID}" == "" ]; then echoit "Assert! ${MPID} empty. Terminating!"; exit 1; fi
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        if [ "${MPID2}" == "" ]; then echoit "Assert! ${MPID2} empty. Terminating!"; exit 1; fi
      fi
      if grep -qi "ERROR. Aborting" ${RUNDIR}/${TRIAL}/log/master.err; then
        if grep -qi "TCP.IP port. Address already in use" ${RUNDIR}/${TRIAL}/log/master.err; then
          echoit "Assert! The text '[ERROR] Aborting' was found in the error log due to a IP port conflict (the port was already in use)"
          removetrial
        else
          if [ ${ADD_RANDOM_OPTIONS} -eq 0 ]; then  # Halt for ADD_RANDOM_OPTIONS=0 runs, they should not produce errors like these, as MYEXTRA should be high-quality/non-faulty
            echoit "Assert! '[ERROR] Aborting' was found in the error log. This is likely an issue with one of the \$MEXTRA (or \$MYSAFE) startup parameters. Saving trial for further analysis, and dumping error log here for quick analysis. Please check the output against the \$MYEXTRA (or \$MYSAFE if it was modified) settings. You may also want to try setting \$MYEXTRA=\"${MYEXTRA}\" directly in start (as created by startup.sh using your base directory)."
            grep "ERROR" ${RUNDIR}/${TRIAL}/log/master.err | tee -a /${WORKDIR}/pquery-run.log
            savetrial
            echoit "Remember to cleanup/delete the rundir:  rm -Rf ${RUNDIR}"
            exit 1
          else  # Do not halt for ADD_RANDOM_OPTIONS=1 runs, they are likely to produce errors like these as MYEXTRA was randomly changed
            echoit "'[ERROR] Aborting' was found in the error log. This is likely an issue with one of the MYEXTRA startup parameters. As ADD_RANDOM_OPTIONS=1, this is likely to be encountered. Not saving trial. If you see this error for every trial however, set \$ADD_RANDOM_OPTIONS=0 & try running pquery-run.sh again. If it still fails, your base \$MYEXTRA setting is faulty."
            grep "ERROR" ${RUNDIR}/${TRIAL}/log/master.err | tee -a /${WORKDIR}/pquery-run.log
            FAILEDSTARTABORT=1
            break
          fi
        fi
      fi
      if [ $(ls -l ${RUNDIR}/${TRIAL}/*/*core* 2>/dev/null | wc -l) -ge 1 ]; then break; fi  # Break the wait-for-server-started loop if a core file is found. Handling of core is done below.
    done
    # Check if mysqld is alive and if so, set ISSTARTED=1 so pquery will run
    if ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/socket.sock ping > /dev/null 2>&1; then
      ISSTARTED=1
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        echoit "Primary Server started ok. Client: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/socket.sock"
        if ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/socket2.sock ping > /dev/null 2>&1; then
          echoit "Secondary server started ok. Client: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/socket.sock"
          ${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/socket2.sock -e "CREATE DATABASE IF NOT EXISTS test;" > /dev/null 2>&1
        fi
      else
        echoit "Server started ok. Client: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/socket.sock"
        ${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test;" > /dev/null 2>&1
      fi
      if [ $PMM -eq 1 ];then
        echoit "Adding Orchestrator user for MySQL replication topology management.."
        printf "[client]\nuser=root\nsocket=${RUNDIR}/${TRIAL}/socket.sock\n" | \
        ${BASEDIR}/bin/mysql --defaults-file=/dev/stdin  -e "GRANT SUPER, PROCESS, REPLICATION SLAVE, RELOAD ON *.* TO 'orc_client_user'@'%' IDENTIFIED BY 'orc_client_password'" 2>/dev/null
        echoit "Starting pmm client for this server..."
        sudo pmm-admin add mysql pq${RANDOMD}-${TRIAL} --socket=${RUNDIR}/${TRIAL}/socket.sock --user=root --query-source=perfschema
      fi
    fi
  elif [[ ${PXC} -eq 1 ]]; then
    mkdir -p ${RUNDIR}/${TRIAL}/
    cp -R ${WORKDIR}/node1.template ${RUNDIR}/${TRIAL}/node1 2>&1
    cp -R ${WORKDIR}/node2.template ${RUNDIR}/${TRIAL}/node2 2>&1
    cp -R ${WORKDIR}/node3.template ${RUNDIR}/${TRIAL}/node3 2>&1

    PXC_MYEXTRA=
    # === PXC Options Stage 1: Add random mysqld options to PXC_MYEXTRA
    if [ ${PXC_ADD_RANDOM_OPTIONS} -eq 1 ]; then
      OPTIONS_TO_ADD=
      NR_OF_OPTIONS_TO_ADD=$(( RANDOM % PXC_MAX_NR_OF_RND_OPTS_TO_ADD + 1 ))
      for X in $(seq 1 ${NR_OF_OPTIONS_TO_ADD}); do
        OPTION_TO_ADD="$(shuf --random-source=/dev/urandom ${PXC_OPTIONS_INFILE} | head -n1)"
        if [ "$(echo ${OPTION_TO_ADD} | sed 's| ||g;s|.*query.alloc.block.size=1125899906842624.*||' )" != "" ]; then  # http://bugs.mysql.com/bug.php?id=78238
          OPTIONS_TO_ADD="${OPTIONS_TO_ADD} ${OPTION_TO_ADD}"
        fi
      done
      echoit "PXC_ADD_RANDOM_OPTIONS=1: adding mysqld option(s) ${OPTIONS_TO_ADD} to this run's PXC_MYEXTRA..."
      PXC_MYEXTRA="${OPTIONS_TO_ADD}"
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        MYEXTRA2="${MYEXTRA2} ${OPTIONS_TO_ADD}"
      fi
    fi
    # === PXC Options Stage 2: Add random wsrep mysqld options to PXC_MYEXTRA
    if [ ${PXC_WSREP_ADD_RANDOM_WSREP_MYSQLD_OPTIONS} -eq 1 ]; then
      OPTIONS_TO_ADD=
      NR_OF_OPTIONS_TO_ADD=$(( RANDOM % PXC_WSREP_MAX_NR_OF_RND_OPTS_TO_ADD + 1 ))
      for X in $(seq 1 ${NR_OF_OPTIONS_TO_ADD}); do
        OPTION_TO_ADD="$(shuf --random-source=/dev/urandom ${PXC_WSREP_OPTIONS_INFILE} | head -n1)"
        OPTIONS_TO_ADD="${OPTIONS_TO_ADD} ${OPTION_TO_ADD}"
      done
      echoit "PXC_WSREP_ADD_RANDOM_WSREP_MYSQLD_OPTIONS=1: adding wsrep provider mysqld option(s) ${OPTIONS_TO_ADD} to this run's PXC_MYEXTRA..."
      PXC_MYEXTRA="${PXC_MYEXTRA} ${OPTIONS_TO_ADD}"
    fi
    # === PXC Options Stage 3: Add random wsrep (Galera) configuration options
    if [ ${PXC_WSREP_PROVIDER_ADD_RANDOM_WSREP_PROVIDER_CONFIG_OPTIONS} -eq 1 ]; then
      OPTIONS_TO_ADD=
      NR_OF_OPTIONS_TO_ADD=$(( RANDOM % PXC_WSREP_PROVIDER_MAX_NR_OF_RND_OPTS_TO_ADD + 1 ))
      for X in $(seq 1 ${NR_OF_OPTIONS_TO_ADD}); do
        OPTION_TO_ADD="$(shuf --random-source=/dev/urandom ${PXC_WSREP_PROVIDER_OPTIONS_INFILE} | head -n1)"
        OPTIONS_TO_ADD="${OPTION_TO_ADD};${OPTIONS_TO_ADD}"
      done
      echoit "PXC_WSREP_PROVIDER_ADD_RANDOM_WSREP_PROVIDER_CONFIG_OPTIONS=1: adding wsrep provider configuration option(s) ${OPTIONS_TO_ADD} to this run..."
      WSREP_PROVIDER_OPT="$OPTIONS_TO_ADD"
    fi
    echo "${MYEXTRA} ${PXC_MYEXTRA}" > ${RUNDIR}/${TRIAL}/MYEXTRA
    echo "${MYINIT}" > ${RUNDIR}/${TRIAL}/MYINIT
    echo "$WSREP_PROVIDER_OPT" > ${RUNDIR}/${TRIAL}/WSREP_PROVIDER_OPT
    if [ ${VALGRIND_RUN} -eq 1 ]; then
      touch  ${RUNDIR}/${TRIAL}/VALGRIND
      echoit "Waiting for all PXC nodes to fully start (note this is slow for Valgrind runs, and can easily take 90-180 seconds even on an high end server)..."
    fi
    pxc_startup
    echoit "Checking 3 node PXC Cluster startup..."
    for X in $(seq 0 10); do
      sleep 1
      CLUSTER_UP=0;
      if ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock ping > /dev/null 2>&1; then
        if [ `${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
        if [ `${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node2/node2_socket.sock -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
        if [ `${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node3/node3_socket.sock -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
        if [ "`${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
        if [ "`${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node2/node2_socket.sock -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
        if [ "`${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node3/node3_socket.sock -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
      fi
      # If count reached 6 (there are 6 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
      if [ ${CLUSTER_UP} -eq 6 ]; then
        ISSTARTED=1
        echoit "3 Node PXC Cluster started ok. Clients:"
        echoit "Node #1: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock"
        echoit "Node #2: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/node2/node2_socket.sock"
        echoit "Node #3: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/node3/node3_socket.sock"
        break
      fi
    done
  elif [[ ${GRP_RPL} -eq 1 ]];then
    mkdir -p ${RUNDIR}/${TRIAL}/
    cp -R ${WORKDIR}/node1.template ${RUNDIR}/${TRIAL}/node1 2>&1
    cp -R ${WORKDIR}/node2.template ${RUNDIR}/${TRIAL}/node2 2>&1
    cp -R ${WORKDIR}/node3.template ${RUNDIR}/${TRIAL}/node3 2>&1
    gr_startup

    CLUSTER_UP=0;
    if [ `${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock -Bse"select count(1) from performance_schema.replication_group_members where member_state='ONLINE'"` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node2/node2_socket.sock -Bse"select count(1) from performance_schema.replication_group_members where member_state='ONLINE'"` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `${BASEDIR}/bin/mysql -uroot -S${RUNDIR}/${TRIAL}/node3/node3_socket.sock -Bse"select count(1) from performance_schema.replication_group_members where member_state='ONLINE'"` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi

    # If count reached 3, then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
    if [ ${CLUSTER_UP} -eq 3 ]; then
      ISSTARTED=1
      echoit "3 Node Group Replication Cluster started ok. Clients:"
      echoit "Node #1: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock"
      echoit "Node #2: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/node2/node2_socket.sock"
      echoit "Node #3: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${RUNDIR}/${TRIAL}/node3/node3_socket.sock"
    fi
  fi

  if [ ${ISSTARTED} -eq 1 ]; then
    rm -f ${RUNDIR}/${TRIAL}/startup_failure_thread-0.sql  # Remove the earlier created fake (SELECT 1; only) file present for startup issues (server is started OK now)
    if [ ${THREADS} -eq 1 ]; then  # Single-threaded run (1 client only)
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then # Single-threaded query correctness run using a chunk from INFILE against two servers to then compare outcomes
        echoit "Taking ${QC_NR_OF_STATEMENTS_PER_TRIAL} lines randomly from ${INFILE} as testcase for this query correctness trial..."
        # Make sure that the code below generates exactly 3 lines (DROP/CREATE/USE) -OR- change the "head -n3" and "sed '1,3d'" (both below) to match any updates made
        echo 'DROP DATABASE test;' > ${RUNDIR}/${TRIAL}/${TRIAL}.sql
        if [ "$(echo ${QC_PRI_ENGINE} | tr [:upper:] [:lower:])" == "rocksdb" -o "$(echo ${QC_SEC_ENGINE} | tr [:upper:] [:lower:])" == "rocksdb" ]; then
          case "$(echo $(( RANDOM % 4 + 1 )))" in
            1) echo 'CREATE DATABASE test DEFAULT CHARACTER SET="Binary" DEFAULT COLLATE="Binary";' >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql;;
            2) echo 'CREATE DATABASE test DEFAULT CHARACTER SET="utf8" DEFAULT COLLATE="utf8_bin";' >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql;;
            3) echo 'CREATE DATABASE test DEFAULT CHARACTER SET="latin1" DEFAULT COLLATE="latin1_bin";' >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql;;
            4) echo 'CREATE DATABASE test DEFAULT CHARACTER SET="utf8mb4" DEFAULT COLLATE="utf8mb4_bin";' >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql;;
          esac
        else
          echo 'CREATE DATABASE test;' >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql
        fi
        echo 'USE test;' >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql
        shuf --random-source=/dev/urandom ${INFILE} | head -n${QC_NR_OF_STATEMENTS_PER_TRIAL} >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql
        awk -v seed=$RANDOM 'BEGIN{srand();} {ORS="#@"int(999999999*rand())"\n"} {print $0}' ${RUNDIR}/${TRIAL}/${TRIAL}.sql > ${RUNDIR}/${TRIAL}/${TRIAL}.new
        rm -f ${RUNDIR}/${TRIAL}/${TRIAL}.sql && mv ${RUNDIR}/${TRIAL}/${TRIAL}.new ${RUNDIR}/${TRIAL}/${TRIAL}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
        echoit "Further processing testcase into two testcases against primary (${QC_PRI_ENGINE}) and secondary (${QC_SEC_ENGINE}) engines..."
        if [ "$(echo ${QC_PRI_ENGINE} | tr [:upper:] [:lower:])" == "rocksdb" -o "$(echo ${QC_SEC_ENGINE} | tr [:upper:] [:lower:])" == "rocksdb" ]; then
          head -n3 ${RUNDIR}/${TRIAL}/${TRIAL}.sql > ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}  # Setup testcase with DROP/CREATE/USE test db
          sed '1,3d' ${RUNDIR}/${TRIAL}/${TRIAL}.sql | \
           sed 's|FOREIGN[ \t]\+KEY||i' | \
           sed 's|FULLTEXT||i' | \
           sed 's|VIRTUAL||i' | \
           sed 's|[ \t]\+TEMPORARY||i' | \
           sed -E 's/row_format.*=.*(;| )+//i' | \
           grep -vi "variables" | \
           grep -vi "\@\@" | \
           grep -viE "show[ \t]+" | \
           grep -viE "analyze[ \t]+" | \
           grep -viE "optimize[ \t]+" | \
           grep -vi "information_schema" | \
           grep -vi "performance_schema" | \
           grep -viE "check[ \t]+" | \
           grep -viE "repair[ \t]+" | \
           grep -viE "explain[ \t]+" | \
           grep -vi "point" | \
           grep -vi "geometry" | \
           grep -vi "linestring" | \
           grep -vi "polygon" | \
           grep -vi "unique" | \
           grep -vi "rand" | \
           grep -vi "uuid" | \
           grep -vi "charset" | \
           grep -vi "character" | \
           grep -vi "collate" | \
           grep -vi "db_row_id" | \
           grep -vi "db_trx_id" | \
           grep -vi "gen_clust_index" | \
           grep -vi "current_time" | \
           grep -vi "curtime" | \
           grep -vi "timestamp" | \
           grep -vi "localtime" | \
           grep -vi "utc_time" | \
           grep -vi "connection_id" | \
           grep -vi "sysdate" | \
           grep -vEi "now[ \t]*\(.{0,4}\)" | \
           grep -vi "flush.*for[ \t]*export" | \
           grep -vi "encrypt[ \t]*(.*)" | \
           grep -vi "compression_dictionary" | \
           grep -vi "start transaction .*with consistent snapshot" | \
           grep -vi "limit rows examined" | \
           grep -vi "set .*read[ -]uncommitted" | \
           grep -vi "set .*serializable" | \
           grep -vi "set .*binlog_format" | \
           grep -vi "max_join_size" | \
           grep -vi "^create table.*unicode" | \
           grep -vi "^create table.*tablespace" | \
           grep -viE "^(create table|alter table).*column_format.*compressed" | \
           grep -vi "^create table.*generated" | \
           grep -vi "^create table.*/tmp/not-existing" | \
           grep -vi "^create table.*compression" | \
           grep -viE "^create( temporary)?.*table.*key_block_size" | \
           grep -vi "^create table.*encryption" | \
           grep -viE "^(create table|alter table).*comment.*__system__" | \
           grep -vi "^select.* sys\." | \
           grep -vi "^select.* mysql\." | \
           grep -vi "^call.* sys\." | \
           grep -vi "^use " | \
           grep -vi "^describe" | \
           grep -vi "password[ \t]*(.*)" | \
           grep -vi "old_password[ \t]*(.*)" | \
           grep -vi "row_count[ \t]*(.*)" | \
           grep -vi "^handler" | \
           grep -vi "^lock.*for backup" | \
           grep -vi "^uninstall.*plugin" | \
           grep -vi "^alter table.*algorithm.*inplace" | \
           grep -vi "^set.*innodb_encrypt_tables" | \
           grep -vi "^insert.*into.*select.*from" | \
           grep -vi "^alter table.*discard tablespace" >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
          cp ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE} ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        elif [ "$(echo ${QC_PRI_ENGINE} | tr [:upper:] [:lower:])" == "tokudb" -o "$(echo ${QC_SEC_ENGINE} | tr [:upper:] [:lower:])" == "tokudb" ]; then
          head -n3 ${RUNDIR}/${TRIAL}/${TRIAL}.sql > ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}  # Setup testcase with DROP/CREATE/USE test db
          sed '1,3d' ${RUNDIR}/${TRIAL}/${TRIAL}.sql | \
           sed 's|FOREIGN[ \t]\+KEY||i' | \
           sed 's|FULLTEXT||i' | \
           sed 's|VIRTUAL||i' | \
           sed 's|CLUSTERING||i' | \
           sed -E 's/row_format.*=.*(;| )+//i' | \
           grep -vi "variables" | \
           grep -vi "\@\@" | \
           grep -viE "show[ \t]+" | \
           grep -viE "analyze[ \t]+" | \
           grep -viE "optimize[ \t]+" | \
           grep -vi "information_schema" | \
           grep -vi "performance_schema" | \
           grep -viE "check[ \t]+" | \
           grep -viE "repair[ \t]+" | \
           grep -viE "explain[ \t]+" | \
           grep -vi "point" | \
           grep -vi "geometry" | \
           grep -vi "linestring" | \
           grep -vi "polygon" | \
           grep -vi "rand" | \
           grep -vi "uuid" | \
           grep -vi "db_row_id" | \
           grep -vi "db_trx_id" | \
           grep -vi "gen_clust_index" | \
           grep -vi "current_time" | \
           grep -vi "curtime" | \
           grep -vi "timestamp" | \
           grep -vi "localtime" | \
           grep -vi "utc_time" | \
           grep -vi "connection_id" | \
           grep -vi "sysdate" | \
           grep -vEi "now[ \t]*\(.{0,4}\)" | \
           grep -vi "flush.*for[ \t]*export" | \
           grep -vi "encrypt[ \t]*(.*)" | \
           grep -vi "compression_dictionary" | \
           grep -vi "limit rows examined" | \
           grep -vi "max_join_size" | \
           grep -vi "^create table.*tablespace" | \
           grep -viE "^(create table|alter table).*column_format.*compressed" | \
           grep -vi "^create table.*generated" | \
           grep -vi "^create table.*/tmp/not-existing" | \
           grep -vi "^create table.*compression" | \
           grep -viE "^create( temporary)?.*table.*key_block_size" | \
           grep -vi "^create table.*encryption" | \
           grep -vi "^select.* sys\." | \
           grep -vi "^select.* mysql\." | \
           grep -vi "^call.* sys\." | \
           grep -vi "^use " | \
           grep -vi "^describe" | \
           grep -vi "password[ \t]*(.*)" | \
           grep -vi "old_password[ \t]*(.*)" | \
           grep -vi "row_count[ \t]*(.*)" | \
           grep -vi "^alter table.*algorithm.*inplace" | \
           grep -vi "^set.*innodb_encrypt_tables" | \
           grep -vi "^uninstall.*plugin" >> ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
          cp ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE} ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        else
          cp ${RUNDIR}/${TRIAL}/${TRIAL}.sql ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
          cp ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE} ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        fi
        sed -i "s|innodb|${QC_PRI_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|innodb|${QC_SEC_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|tokudb|${QC_PRI_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|tokudb|${QC_SEC_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|rocksdb|${QC_PRI_ENGINE}|gi"    ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|rocksdb|${QC_SEC_ENGINE}|gi"    ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|myisam|${QC_PRI_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|myisam|${QC_SEC_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|memory|${QC_PRI_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|memory|${QC_SEC_ENGINE}|gi"     ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|merge|${QC_PRI_ENGINE}|gi"      ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|merge|${QC_SEC_ENGINE}|gi"      ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|csv|${QC_PRI_ENGINE}|gi"        ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|csv|${QC_SEC_ENGINE}|gi"        ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|[m]aria|${QC_PRI_ENGINE}|gi"    ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|[m]aria|${QC_SEC_ENGINE}|gi"    ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|heap|${QC_PRI_ENGINE}|gi"       ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|heap|${QC_SEC_ENGINE}|gi"       ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|federated|${QC_PRI_ENGINE}|gi"  ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|federated|${QC_SEC_ENGINE}|gi"  ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|archive|${QC_PRI_ENGINE}|gi"    ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|archive|${QC_SEC_ENGINE}|gi"    ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|mrg_myisam|${QC_PRI_ENGINE}|gi" ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|mrg_myisam|${QC_SEC_ENGINE}|gi" ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|cassandra|${QC_PRI_ENGINE}|gi"  ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|cassandra|${QC_SEC_ENGINE}|gi"  ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|ndb|${QC_PRI_ENGINE}|gi"        ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|ndb|${QC_SEC_ENGINE}|gi"        ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        sed -i "s|ndbcluster|${QC_PRI_ENGINE}|gi" ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}
        sed -i "s|ndbcluster|${QC_SEC_ENGINE}|gi" ${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}
        SQL_FILE_1="--infile=${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_PRI_ENGINE}"
        SQL_FILE_2="--infile=${RUNDIR}/${TRIAL}/${TRIAL}.sql.${QC_SEC_ENGINE}"
        if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
          echoit "Starting Primary pquery run for engine ${QC_PRI_ENGINE} (log stored in ${RUNDIR}/${TRIAL}/pquery1.log)..."
          if [ ${QUERY_CORRECTNESS_MODE} -ne 2 ]; then
            ${PQUERY_BIN} ${SQL_FILE_1} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --user=root --socket=${RUNDIR}/${TRIAL}/socket.sock >${RUNDIR}/${TRIAL}/pquery1.log 2>&1
            PQPID="$!"
            mv ${RUNDIR}/${TRIAL}/pquery_thread-0.sql ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
            mv ${RUNDIR}/${TRIAL}/pquery_thread-0.out ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.out 2>&1 | tee -a /${WORKDIR}/pquery-run.log
          else
            ${PQUERY_BIN} ${SQL_FILE_1} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --log-client-output --user=root --log-query-number --socket=${RUNDIR}/${TRIAL}/socket.sock >${RUNDIR}/${TRIAL}/pquery1.log 2>&1
            PQPID="$!"
            mv ${RUNDIR}/${TRIAL}/default.node.tld_thread-0.sql ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
            mv ${RUNDIR}/${TRIAL}/default.node.tld_thread-0.out ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.out 2>&1 | tee -a /${WORKDIR}/pquery-run.log
          fi
          echoit "Starting Secondary pquery run for engine ${QC_SEC_ENGINE} (log stored in ${RUNDIR}/${TRIAL}/pquery2.log)..."
          if [ ${QUERY_CORRECTNESS_MODE} -ne 2 ]; then
            ${PQUERY_BIN} ${SQL_FILE_2} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --user=root --socket=${RUNDIR}/${TRIAL}/socket2.sock >${RUNDIR}/${TRIAL}/pquery2.log 2>&1
            PQPID2="$!"
            mv ${RUNDIR}/${TRIAL}/pquery_thread-0.sql ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
            mv ${RUNDIR}/${TRIAL}/pquery_thread-0.out ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.out 2>&1 | tee -a /${WORKDIR}/pquery-run.log
            grep -o "CHANGED: [0-9]\+" ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.sql > ${RUNDIR}/${TRIAL}/${QC_PRI_ENGINE}.result
            grep -o "CHANGED: [0-9]\+" ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.sql > ${RUNDIR}/${TRIAL}/${QC_SEC_ENGINE}.result
          else
            ${PQUERY_BIN} ${SQL_FILE_2} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --log-client-output --user=root --log-query-number --socket=${RUNDIR}/${TRIAL}/socket2.sock >${RUNDIR}/${TRIAL}/pquery2.log 2>&1
            PQPID2="$!"
            mv ${RUNDIR}/${TRIAL}/default.node.tld_thread-0.sql ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
            mv ${RUNDIR}/${TRIAL}/default.node.tld_thread-0.out ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.out 2>&1 | tee -a /${WORKDIR}/pquery-run.log
            diff ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.out ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.out > ${RUNDIR}/${TRIAL}/diff.result
            echo "${QC_PRI_ENGINE}" > ${RUNDIR}/${TRIAL}/diff.left    # When changing this, also search for/edit other '\.left' and '\.right' occurences in this file
            echo "${QC_SEC_ENGINE}" > ${RUNDIR}/${TRIAL}/diff.right
          fi
        else
          ## TODO: Add QUERY_CORRECTNESS_MODE checks (as seen above) to the code below also. FTM, the code below only does "changed rows" comparison
          echoit "Starting Primary pquery run for engine ${QC_PRI_ENGINE} (log stored in ${RUNDIR}/${TRIAL}/pquery1.log)..."
          ${PQUERY_BIN} ${SQL_FILE_1} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --user=root --socket=${RUNDIR}/${TRIAL}/node1/node1_socket.sock >${RUNDIR}/${TRIAL}/pquery1.log 2>&1
          PQPID="$!"
          mv ${RUNDIR}/${TRIAL}/pquery_thread-0.sql ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
          grep -o "CHANGED: [0-9]\+" ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.sql > ${RUNDIR}/${TRIAL}/${QC_PRI_ENGINE}.result
          echoit "Starting Secondary pquery run for engine ${QC_SEC_ENGINE} (log stored in ${RUNDIR}/${TRIAL}/pquery2.log)..."
          ${PQUERY_BIN} ${SQL_FILE_2} --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --user=root --socket=${RUNDIR}/${TRIAL}/node2/node2_socket.sock >${RUNDIR}/${TRIAL}/pquery2.log 2>&1
          PQPID2="$!"
          mv ${RUNDIR}/${TRIAL}/pquery_thread-0.sql ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.sql 2>&1 | tee -a /${WORKDIR}/pquery-run.log
          grep -o "CHANGED: [0-9]\+" ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.sql > ${RUNDIR}/${TRIAL}/${QC_SEC_ENGINE}.result
        fi
      else  # Not a query correctness testing run
        echoit "Starting pquery (log stored in ${RUNDIR}/${TRIAL}/pquery.log)..."
        if [ ${QUERY_DURATION_TESTING} -eq 1 ]; then  # Query duration testing run
          if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
            ${PQUERY_BIN} --infile=${INFILE} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --log-query-duration --user=root --socket=${RUNDIR}/${TRIAL}/socket.sock >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
            PQPID="$!"
          else
            if [[ ${PXC_CLUSTER_RUN} -eq 1 ]];then
              cat ${PXC_CLUSTER_CONFIG} \
                | sed -e "s|\/tmp|${RUNDIR}\/${TRIAL}|" \
                | sed -e "s|\/home\/ramesh\/percona-qa|${SCRIPT_PWD}|" \
                > ${RUNDIR}/${TRIAL}/pquery-cluster.cfg
              ${PQUERY_BIN} --config-file=${RUNDIR}/${TRIAL}/pquery-cluster.cfg >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
              PQPID="$!"
            elif [[ ${GRP_RPL_CLUSTER_RUN} -eq 1 ]];then
              cat ${GRP_RPL_CLUSTER_CONFIG} \
                | sed -e "s|\/tmp|${RUNDIR}\/${TRIAL}|" \
                | sed -e "s|\/home\/ramesh\/percona-qa|${SCRIPT_PWD}|" \
                > ${RUNDIR}/${TRIAL}/pquery-cluster.cfg
              ${PQUERY_BIN} --config-file=${RUNDIR}/${TRIAL}/pquery-cluster.cfg >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
              PQPID="$!"
            else
              ${PQUERY_BIN} --infile=${INFILE} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --log-query-duration --user=root --socket=${RUNDIR}/${TRIAL}/node1/node1_socket.sock >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
              PQPID="$!"
            fi
          fi
        else  # Standard pquery run / Not a query duration testing run
          if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
            ${PQUERY_BIN} --infile=${INFILE} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --user=root --socket=${RUNDIR}/${TRIAL}/socket.sock >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
            PQPID="$!"
          else
            if [[ ${PXC_CLUSTER_RUN} -eq 1 ]];then
              cat ${PXC_CLUSTER_CONFIG} \
                | sed -e "s|\/tmp|${RUNDIR}\/${TRIAL}|" \
                | sed -e "s|\/home\/ramesh\/percona-qa|${SCRIPT_PWD}|" \
                > ${RUNDIR}/${TRIAL}/pquery-cluster.cfg
              ${PQUERY_BIN} --config-file=${RUNDIR}/${TRIAL}/pquery-cluster.cfg >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
              PQPID="$!"
            elif [[ ${GRP_RPL_CLUSTER_RUN} -eq 1 ]];then
              cat ${GRP_RPL_CLUSTER_CONFIG} \
                | sed -e "s|\/tmp|${RUNDIR}\/${TRIAL}|" \
                | sed -e "s|\/home\/ramesh\/percona-qa|${SCRIPT_PWD}|" \
                > ${RUNDIR}/${TRIAL}/pquery-cluster.cfg
              ${PQUERY_BIN} --config-file=${RUNDIR}/${TRIAL}/pquery-cluster.cfg >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
              PQPID="$!"
            else
              ${PQUERY_BIN} --infile=${INFILE} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --user=root --socket=${RUNDIR}/${TRIAL}/node1/node1_socket.sock >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
              PQPID="$!"
            fi
          fi
        fi
      fi
    else
      if [ ${CRASH_RECOVERY_TESTING} -eq 1 ]; then
        SQL_FILE="--infile=${INFILE}"
      else
        # Multi-threaded run using a chunk from INFILE (${THREADS} clients)
        echoit "Taking ${MULTI_THREADED_TESTC_LINES} lines randomly from ${INFILE} as testcase for this multi-threaded trial..."
        shuf --random-source=/dev/urandom ${INFILE} | head -n${MULTI_THREADED_TESTC_LINES} > ${RUNDIR}/${TRIAL}/${TRIAL}.sql
        SQL_FILE="--infile=${RUNDIR}/${TRIAL}/${TRIAL}.sql"
      fi
      # Debug echo "-------"; cat ${RUNDIR}/${TRIAL}/${TRIAL}.sql; echo "-------"
      if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
        ${PQUERY_BIN} ${SQL_FILE} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --user=root --socket=${RUNDIR}/${TRIAL}/socket.sock >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
        PQPID="$!"
      else
        ${PQUERY_BIN} ${SQL_FILE} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${RUNDIR}/${TRIAL} --log-all-queries --log-failed-queries --user=root --socket=${RUNDIR}/${TRIAL}/node1/node1_socket.sock >${RUNDIR}/${TRIAL}/pquery.log 2>&1 &
        PQPID="$!"
      fi
    fi
    TIMEOUT_REACHED=0
    if [ ${QUERY_CORRECTNESS_TESTING} -ne 1 ]; then
      echoit "pquery running (Max duration: ${PQUERY_RUN_TIMEOUT}s)..."
      for X in $(seq 1 ${PQUERY_RUN_TIMEOUT}); do
        sleep 1
        if grep -qi "error while loading shared libraries" ${RUNDIR}/${TRIAL}/pquery.log; then
          if grep -qi "error while loading shared libraries.*libssl" ${RUNDIR}/${TRIAL}/pquery.log; then
            echoit "$(grep -i "error while loading shared libraries" ${RUNDIR}/${TRIAL}/pquery.log)"
            echoit "Assert: There was an error loading the shared/dynamic libssl library linked to from within pquery. You may want to try and install a package similar to libssl-dev. If that is already there, try instead to build pquery on this particular machine. Sometimes there are differences seen between Centos and Ubuntu. Perhaps we need to have a pquery build for each of those separately."
	      else
            echoit "Assert: There was an error loading the shared/dynamic mysql client library linked to from within pquery. Ref. ${RUNDIR}/${TRIAL}/pquery.log to see the error. The solution is to ensure that LD_LIBRARY_PATH is set correctly (for example: execute '$ export LD_LIBRARY_PATH=<your_mysql_base_directory>/lib' in your shell. This will happen only if you use pquery without statically linked client libraries, and this in turn would happen only if you compiled pquery yourself instead of using the pre-built binaries available in https://github.com/Percona-QA/percona-qa (ref subdirectory/files ./pquery/pquery*) - which are normally used by this script (hence this situation is odd to start with). The pquery binaries in percona-qa all include a statically linked mysql client library matching the mysql flavor (PS,MS,MD,WS) it was built for. Another reason for this error may be that (having used pquery without statically linked client binaries as mentioned earlier) the client libraries are not available at the location set in LD_LIBRARY_PATH (which is currently set to '${LD_LIBRARY_PATH}'."
	      fi
          exit 1
        fi
        if [ "`ps -ef | grep ${PQPID} | grep -v grep`" == "" ]; then  # pquery ended
          break
        fi
        if [ ${CRASH_RECOVERY_TESTING} -eq 1 ]; then
          if [ $X -ge $CRASH_RECOVERY_KILL_BEFORE_END_SEC ]; then
             kill -9 ${MPID} >/dev/null 2>&1;
             sleep 2
             echoit "killed for crash testing"
             break
          fi
        fi
        # Initiate Percona Xtrabackup
        if [[ ${PXB_CRASH_RUN} -eq 1 ]]; then
          if [[ $X -ge $PXB_INITIALIZE_BACKUP_SEC ]]; then
            $PXB_BASEDIR/bin/xtrabackup --user=root --password='' --backup --target-dir=${RUNDIR}/${TRIAL}/xb_full -S${RUNDIR}/${TRIAL}/socket.sock --datadir=${RUNDIR}/${TRIAL}/data --lock-ddl > ${RUNDIR}/${TRIAL}/backup.log 2>&1
            $PXB_BASEDIR/bin/xtrabackup --prepare --target_dir=${RUNDIR}/${TRIAL}/xb_full --lock-ddl > ${RUNDIR}/${TRIAL}/prepare_backup.log 2>&1
            echoit "Backup completed"
            PXB_CHECK=1
            break 
          fi
        fi
        if [ $X -ge ${PQUERY_RUN_TIMEOUT} ]; then
          echoit "${PQUERY_RUN_TIMEOUT}s timeout reached. Terminating this trial..."
          TIMEOUT_REACHED=1
          break
        fi
      done
      if [ $PMM -eq 1 ]; then
        if ps -p  ${MPID} > /dev/null ; then
          echoit "PMM trial info : Sleeping 5 mints to check the data collection status"
          sleep 300
        fi
      fi
    fi
  else
    if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
      if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
        echoit "Either the Primary server (PID: ${MPID} | Socket: ${RUNDIR}/${TRIAL}/socket.sock), or the Secondary server (PID: ${MPID2} | Socket: ${RUNDIR}/${TRIAL}/socket2.sock) failed to start after ${MYSQLD_START_TIMEOUT} seconds. Will issue extra kill -9 to ensure it's gone..."
        (sleep 0.2; kill -9 ${MPID2} >/dev/null 2>&1; timeout -k4 -s9 4s wait ${MPID2} >/dev/null 2>&1) &
        timeout -k5 -s9 5s wait ${MPID2} >/dev/null 2>&1
      else
        echoit "Server (PID: ${MPID} | Socket: ${RUNDIR}/${TRIAL}/socket.sock) failed to start after ${MYSQLD_START_TIMEOUT} seconds. Will issue extra kill -9 to ensure it's gone..."
      fi
      (sleep 0.2; kill -9 ${MPID} >/dev/null 2>&1; timeout -k4 -s9 4s wait ${MPID} >/dev/null 2>&1) &
      timeout -k5 -s9 5s wait ${MPID} >/dev/null 2>&1
      sleep 2; sync
    elif [[ ${PXC} -eq 1 ]]; then
      echoit "3 Node PXC Cluster failed to start after ${PXC_START_TIMEOUT} seconds. Will issue an extra cleanup to ensure nothing remains..."
      (ps -ef | grep 'node[0-9]_socket' | grep ${RUNDIR} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
      sleep 2; sync
    elif [[ ${GRP_RPL} -eq 1 ]]; then
      echoit "3 Node Group Replication Cluster failed to start after ${GRP_RPL_START_TIMEOUT} seconds. Will issue an extra cleanup to ensure nothing remains..."
      (ps -ef | grep 'node[0-9]_socket' | grep ${RUNDIR} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
      sleep 2; sync
    fi
  fi
  if [ ${VALGRIND_RUN} -eq 1 ]; then
    echoit "Cleaning up & saving results if needed. Note that this may take up to 10 minutes because this is a Valgrind run. You may also see a mysqladmin killed message..."
  else
    echoit "Cleaning up & saving results if needed..."
  fi
  TRIAL_SAVED=0;
  sleep 2  # Delay to ensure core was written completely (if any)
  # NOTE**: Do not kill PQPID here/before shutdown. The reason is that pquery may still be writing queries it's executing to the log. The only way to halt pquery properly is by
  # actually shutting down the server which will auto-terminate pquery due to 250 consecutive queries failing. If 250 queries failed and ${PQUERY_RUN_TIMEOUT}s timeout was reached,
  # and if there is no core/Valgrind issue and there is no output of percona-qa/text_string.sh either (in case core dumps are not configured correctly, and thus no core file is
  # generated, text_string.sh will still produce output in case the server crashed based on the information in the error log), then we do not need to save this trial (as it is a
  # standard occurence for this to happen). If however we saw 250 queries failed before the timeout was complete, then there may be another problem and the trial should be saved.
  if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
    if [ ${VALGRIND_RUN} -eq 1 ]; then  # For Valgrind, we want the full Valgrind output in the error log, hence we need a proper/clean (and slow...) shutdown
      # Note that even if mysqladmin is killed with the 'timeout --signal=9', it will not affect the actual state of mysqld, all that was terminated was mysqladmin.
      # Thus, mysqld would (presumably) have received a shutdown signal (even if the timeout was 2 seconds it likely would have)
      # ==========================================================================================================================================================
      # TODO: the timeout...mysqladmin shutdown can be improved further to catch shutdown issues. For this, a new special "CATCH_SHUTDOWN=0/1" mode should be
      #       added (because the runs would be much slower, so you would want to run this on-demand), and a much longer timeout should be given for mysqladmin
      #       to succeed getting the server down (3 minutes for single thread runs for example?) if the shutdown fails to complete (i.e. exit status code of
      #       timeout is 137 as the timeout took place), then a shutdown issue is likely present. It should not take 3+ minutes to shutdown a server. There a
      #       good number of trials that seem to run into this situation. Likely a subset of them will be related to the already seen shutdown issues in TokuDB.
      # UPDATE: As an intial stopgap workaround, the timeout was increased to 90 seconds, and the timeout exit code is checked. Trials are saved when this
      #         happens and a special "SHUTDOWN_TIMEOUT_ISSUE empty file is saved in the trial's directory. pquery-results has been updated to scan for this file
      # ==========================================================================================================================================================
      timeout --signal=9 90s ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/socket.sock shutdown > /dev/null 2>&1  # Proper/clean shutdown attempt (up to 90 sec wait), necessary to get full Valgrind output in error log + see NOTE** above
      if [ $? -eq 137 ]; then
        echoit "mysqld failed to shutdown within 90 seconds for this trial, saving it (pquery-results.sh will show these trials seperately)..."
        touch ${RUNDIR}/${TRIAL}/SHUTDOWN_TIMEOUT_ISSUE
        savetrial
        TRIAL_SAVED=1
      fi
      VALGRIND_SUMMARY_FOUND=0
      for X in $(seq 0 600); do  # Wait for full Valgrind output in error log
        sleep 1
        if [ ! -r ${RUNDIR}/${TRIAL}/log/master.err ]; then
          echoit "Assert: ${RUNDIR}/${TRIAL}/log/master.err not found during a Valgrind run. Please check. Trying to continue, but something is wrong already..."
          break
        elif egrep -qi "==[0-9]+== ERROR SUMMARY: [0-9]+ error" ${RUNDIR}/${TRIAL}/log/master.err; then  # Summary found, Valgrind is done
          VALGRIND_SUMMARY_FOUND=1
          sleep 2
          break
        fi
      done
      if [ ${VALGRIND_SUMMARY_FOUND} -eq 0 ]; then
        kill -9 ${MPID} >/dev/null 2>&1;
        if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
          kill -9 ${MPID2} >/dev/null 2>&1;
        fi
        sleep 2  # <^ Make sure mysqld is gone
        echoit "Odd mysqld hang detected (mysqld did not terminate even after 600 seconds), saving this trial... "
        if [ ${TRIAL_SAVED} -eq 0 ]; then
          savetrial
          TRIAL_SAVED=1
        fi
      fi
    else
      if [ ${QUERY_CORRECTNESS_TESTING} -ne 1 ]; then
        timeout --signal=9 90s ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/socket.sock shutdown > /dev/null 2>&1  # Proper/clean shutdown attempt (up to 20 sec wait), necessary to get full Valgrind output in error log + see NOTE** above
        if [ $? -eq 137 ]; then
          echoit "mysqld failed to shutdown within 90 seconds for this trial, saving it (pquery-results.sh will show these trials seperately)..."
          touch ${RUNDIR}/${TRIAL}/SHUTDOWN_TIMEOUT_ISSUE
          savetrial
          TRIAL_SAVED=1
        fi
        sleep 2
      fi
    fi
    (sleep 0.2; kill -9 ${MPID} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${MPID} >/dev/null 2>&1) &  # Terminate mysqld
    (sleep 0.2; kill -9 ${PQPID} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${PQPID} >/dev/null 2>&1) &  # Terminate pquery (if it went past ${PQUERY_RUN_TIMEOUT} time, also see NOTE** above)
    if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
      (sleep 0.2; kill -9 ${MPID2} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${MPID2} >/dev/null 2>&1) &  # Terminate mysqld
      (sleep 0.2; kill -9 ${PQPID2} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${PQPID2} >/dev/null 2>&1) &  # Terminate pquery (if it went past ${PQUERY_RUN_TIMEOUT} time, also see NOTE** above)
    fi
    sleep 1  # <^ Make sure all is gone
  elif [[ ${PXC} -eq 1 || ${GRP_RPL} -eq 1 ]]; then
    if [ ${VALGRIND_RUN} -eq 1 ]; then # For Valgrind, we want the full Valgrind output in the error log, hence we need a proper/clean (and slow...) shutdown
      # Note that even if mysqladmin is killed with the 'timeout --signal=9', it will not affect the actual state of mysqld, all that was terminated was mysqladmin.
      # Thus, mysqld would (presumably) have received a shutdown signal (even if the timeout was 2 seconds it likely would have)
      # Proper/clean shutdown attempt (up to 20 sec wait), necessary to get full Valgrind output in error log
      timeout --signal=9 90s ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/node3/node3_socket.sock shutdown > /dev/null 2>&1
      if [ $? -eq 137 ]; then
        echoit "mysqld for node3 failed to shutdown within 90 seconds for this trial, saving it (pquery-results.sh will show these trials seperately)..."
        touch ${RUNDIR}/${TRIAL}/SHUTDOWN_TIMEOUT_ISSUE
        savetrial
        TRIAL_SAVED=1
      fi
      timeout --signal=9 90s ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/node2/node2_socket.sock shutdown > /dev/null 2>&1
      if [ $? -eq 137 ]; then
        echoit "mysqld for node2 failed to shutdown within 90 seconds for this trial, saving it (pquery-results.sh will show these trials seperately)..."
        touch ${RUNDIR}/${TRIAL}/SHUTDOWN_TIMEOUT_ISSUE
        savetrial
        TRIAL_SAVED=1
      fi
      timeout --signal=9 90s ${BASEDIR}/bin/mysqladmin -uroot -S${RUNDIR}/${TRIAL}/node1/node1_socket.sock shutdown > /dev/null 2>&1
      if [ $? -eq 137 ]; then
        echoit "mysqld for node1 failed to shutdown within 90 seconds for this trial, saving it (pquery-results.sh will show these trials seperately)..."
        touch ${RUNDIR}/${TRIAL}/SHUTDOWN_TIMEOUT_ISSUE
        savetrial
        TRIAL_SAVED=1
      fi
      for X in $(seq 0 600); do  # Wait for full Valgrind output in error log
        sleep 1
        if [[ ! -r ${RUNDIR}/${TRIAL}/node1/node1.err || ! -r ${RUNDIR}/${TRIAL}/node2/node2.err || ! -r ${RUNDIR}/${TRIAL}/node2/node2.err ]]; then
          echoit "Assert: PXC error logs (${RUNDIR}/${TRIAL}/node[13]/node[13].err) not found during a Valgrind run. Please check. Trying to continue, but something is wrong already..."
          break
        elif [ `egrep  "==[0-9]+== ERROR SUMMARY: [0-9]+ error"  ${RUNDIR}/${TRIAL}/node*/node*.err | wc -l` -eq 3 ]; then # Summary found, Valgrind is done
          VALGRIND_SUMMARY_FOUND=1
          sleep 2
          break
        fi
      done
      if [ ${VALGRIND_SUMMARY_FOUND} -eq 0 ]; then
        kill -9 ${PQPID} >/dev/null 2>&1;
        (ps -ef | grep 'node[0-9]_socket' | grep ${RUNDIR} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
        sleep 1  # <^ Make sure mysqld is gone
        echoit "Odd mysqld hang detected (mysqld did not terminate even after 600 seconds), saving this trial... "
        if [ ${TRIAL_SAVED} -eq 0 ]; then
          savetrial
          TRIAL_SAVED=1
        fi
      fi
    fi
    (ps -ef | grep 'node[0-9]_socket' | grep ${RUNDIR} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
    (sleep 0.2; kill -9 ${PQPID} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${PQPID} >/dev/null 2>&1) &  # Terminate pquery (if it went past ${PQUERY_RUN_TIMEOUT} time)
    sleep 2; sync
  fi
  if [ ${ISSTARTED} -eq 1 -a ${TRIAL_SAVED} -ne 1 ]; then  # Do not try and print pquery log for a failed mysqld start
    if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
      echoit "Pri engine pquery run details:$(grep -i 'SUMMARY.*queries failed' ${RUNDIR}/${TRIAL}/*.sql ${RUNDIR}/${TRIAL}/*.log | sed 's|.*:||')"
      echoit "Sec engine pquery run details:$(grep -i 'SUMMARY.*queries failed' ${RUNDIR}/${TRIAL}/*.sql ${RUNDIR}/${TRIAL}/*.log | sed 's|.*:||')"
    else
      echoit "pquery run details:$(grep -i 'SUMMARY.*queries failed' ${RUNDIR}/${TRIAL}/*.sql ${RUNDIR}/${TRIAL}/*.log | sed 's|.*:||')"
    fi
  fi
  if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 -a $(ls -l ${RUNDIR}/${TRIAL}/*/*core* 2>/dev/null | wc -l) -eq 0 -a "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/log/master.err 2>/dev/null)" == "" ]; then  # If a core is found (or text_string.sh sees a crash) when query correctness testing is in progress, it will process it as a normal crash (without considering query correctness)
    if [ "${FAILEDSTARTABORT}" != "1" ]; then
      if [ ${QUERY_CORRECTNESS_MODE} -ne 2 ]; then
        QC_RESULT1=$(diff ${RUNDIR}/${TRIAL}/${QC_PRI_ENGINE}.result ${RUNDIR}/${TRIAL}/${QC_SEC_ENGINE}.result)
        #QC_RESULT2=$(cat ${RUNDIR}/${TRIAL}/pquery1.log | grep -i 'SUMMARY' | sed 's|^.*:|pquery summary:|')
        #QC_RESULT3=$(cat ${RUNDIR}/${TRIAL}/pquery2.log | grep -i 'SUMMARY' | sed 's|^.*:|pquery summary:|')
      else
        QC_RESULT1=$(diff <(sed "s@${QC_PRI_ENGINE}@${QC_SEC_ENGINE}@g" ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_PRI_ENGINE}.out) ${RUNDIR}/${TRIAL}/pquery_thread-0.${QC_SEC_ENGINE}.out)
      fi
      QC_DIFF_FOUND=0
      if [ "${QC_RESULT1}" != "" ]; then
        echoit "Found $(echo ${QC_RESULT1} | wc -l) differences between ${QC_PRI_ENGINE} and ${QC_SEC_ENGINE} results. Saving trial..."
        QC_DIFF_FOUND=1
      fi
      #if [ "${QC_RESULT2}" != "${QC_RESULT3}" ]; then
      #  echoit "Found differences in pquery execution success between ${QC_PRI_ENGINE} and ${QC_SEC_ENGINE} results. Saving trial..."
      #  QC_DIFF_FOUND=1
      #fi
      if [ ${QC_DIFF_FOUND} -eq 1 ]; then
        savetrial
        TRIAL_SAVED=1
      fi
    fi
  else
    if [ ${VALGRIND_RUN} -eq 1 ]; then
      VALGRIND_ERRORS_FOUND=0; VALGRIND_CHECK_1=
      # What follows next are 3 different ways of checking if Valgrind issues were seen, mostly to ensure that no Valgrind issues go unseen, especially if log is not complete
      VALGRIND_CHECK_1=$(grep "==[0-9]\+== ERROR SUMMARY: [0-9]\+ error" ${RUNDIR}/${TRIAL}/log/master.err | sed 's|.*ERROR SUMMARY: \([0-9]\+\) error.*|\1|')
      if [ "${VALGRIND_CHECK_1}" == "" ]; then VALGRIND_CHECK_1=0; fi
      if [ ${VALGRIND_CHECK_1} -gt 0 ]; then
        VALGRIND_ERRORS_FOUND=1;
      fi
      if egrep -qi "^[ \t]*==[0-9]+[= \t]+[atby]+[ \t]*0x" ${RUNDIR}/${TRIAL}/log/master.err; then
        VALGRIND_ERRORS_FOUND=1;
      fi
      if egrep -qi "==[0-9]+== ERROR SUMMARY: [1-9]" ${RUNDIR}/${TRIAL}/log/master.err; then
        VALGRIND_ERRORS_FOUND=1;
      fi
      if [ ${VALGRIND_ERRORS_FOUND} -eq 1 ]; then
        VALGRIND_TEXT=`${SCRIPT_PWD}/valgrind_string.sh ${RUNDIR}/${TRIAL}/log/master.err`
        echoit "Valgrind error detected: ${VALGRIND_TEXT}"
        if [ ${TRIAL_SAVED} -eq 0 ]; then
          savetrial
          TRIAL_SAVED=1
        fi
      else
        # Report that no Valgrnid errors were found & Include ERROR SUMMARY from error log
        echoit "No Valgrind errors detected. $(grep "==[0-9]\+== ERROR SUMMARY: [0-9]\+ error" ${RUNDIR}/${TRIAL}/log/master.err | sed 's|.*ERROR S|ERROR S|')"
      fi
    fi
    if [ ${TRIAL_SAVED} -eq 0 ]; then
      if [ $(ls -l ${RUNDIR}/${TRIAL}/*/*core* 2>/dev/null | wc -l) -ge 1 -o "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/log/master.err 2>/dev/null)" != "" -o "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node1/node1.err 2>/dev/null)" != "" -o "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node2/node2.err 2>/dev/null)" != "" -o "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node3/node3.err 2>/dev/null)" != "" ]; then
        if [ $(ls -l ${RUNDIR}/${TRIAL}/*/*core* 2>/dev/null | wc -l) -ge 1 ]; then
          echoit "mysqld coredump detected at $(ls ${RUNDIR}/${TRIAL}/*/*core* 2>/dev/null)"
        else
          echoit "mysqld crash detected in the error log via text_string.sh scan"
        fi
        if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
          echoit "Bug found (as per error log): $(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/log/master.err)"
        elif [[ ${PXC} -eq 1 || ${GRP_RPL} -eq 1 ]]; then
          if [ "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node1/node1.err 2>/dev/null)" != "" ]; then echoit "Bug found in PXC/GR node #1 (as per error log): $(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node1/node1.err)"; fi
          if [ "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node2/node2.err 2>/dev/null)" != "" ]; then echoit "Bug found in PXC/GR node #2 (as per error log): $(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node2/node2.err)"; fi
          if [ "$(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node3/node3.err 2>/dev/null)" != "" ]; then echoit "Bug found in PXC/GR node #3 (as per error log): $(${SCRIPT_PWD}/text_string.sh ${RUNDIR}/${TRIAL}/node3/node3.err)"; fi
        fi
        savetrial
        TRIAL_SAVED=1
      elif [ $(grep "SIGKILL myself" ${RUNDIR}/${TRIAL}/log/master.err | wc -l) -ge 1 ]; then
        echoit "'SIGKILL myself' detected in the mysqld error log for this trial; saving this trial"
        savetrial
        TRIAL_SAVED=1
      elif [ $(grep "MySQL server has gone away" ${RUNDIR}/${TRIAL}/*.sql | wc -l) -ge 200 -a ${TIMEOUT_REACHED} -eq 0 ]; then
        echoit "'MySQL server has gone away' detected >=200 times for this trial, and the pquery timeout was not reached; saving this trial for further analysis"
        savetrial
        TRIAL_SAVED=1
      elif [ $(grep "ERROR:" ${RUNDIR}/${TRIAL}/log/master.err | wc -l) -ge 1 ]; then
        echoit "ASAN issue detected in the mysqld error log for this trial; saving this trial"
        savetrial
        TRIAL_SAVED=1
      elif [ ${SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY} -eq 0 ]; then
        echoit "Saving full trial outcome (as SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=0 and so trials are saved irrespective of whether an issue was detected or not)"
        savetrial
        TRIAL_SAVED=1
      elif [[ ${PXB_CHECK} -eq 1 ]]; then
        echoit "Saving this trial for backup restore analysis"
        savetrial
        TRIAL_SAVED=1
        PXB_CHECK=0
      else
        if [ ${SAVE_SQL} -eq 1 ]; then
          if [ ${VALGRIND_RUN} -eq 1 ]; then
            if [ ${VALGRIND_ERRORS_FOUND} -ne 1 ]; then
              echoit "Not saving anything for this trial (as SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=1, and no issue was seen), except the SQL trace (as SAVE_SQL=1)"
            fi
          else
            echoit "Not saving anything for this trial (as SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=1, and no issue was seen), except the SQL trace (as SAVE_SQL=1)"
          fi
          savesql
        else
          if [ ${VALGRIND_RUN} -eq 1 ]; then
            if [ ${VALGRIND_ERRORS_FOUND} -ne 1 ]; then
              echoit "Not saving anything for this trial (as SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=1 and SAVE_SQL=0, and no issue was seen)"
            fi
          else
            echoit "Not saving anything for this trial (as SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY=1 and SAVE_SQL=0, and no issue was seen)"
          fi
        fi
      fi
    fi
    if [ ${TRIAL_SAVED} -eq 0 ]; then
      removetrial
    fi
  fi
}

# Setup
if [[ "${INFILE}" == *".tar."* ]]; then
  echoit "The input file is a compressed tarball. This script will untar the file in the same location as the tarball. Please note this overwrites any existing files with the same names as those in the tarball, if any. If the sql input file needs patching (and is part of the github repo), please remember to update the tarball with the new file."
  STORECURPWD=${PWD}
  cd $(echo ${INFILE} | sed 's|/[^/]\+\.tar\..*|/|')  # Change to the directory containing the input file
  tar -xf ${INFILE}
  cd ${STORECURPWD}
  INFILE=$(echo ${INFILE} | sed 's|\.tar\..*||')
fi
rm -Rf ${WORKDIR} ${RUNDIR}
mkdir ${WORKDIR} ${WORKDIR}/log ${RUNDIR}
WORKDIRACTIVE=1
# User for recovery testing
echo "create user recovery@'%';grant all on *.* to recovery@'%';flush privileges;" > ${WORKDIR}/recovery-user.sql
if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
  echoit "Workdir: ${WORKDIR} | Rundir: ${RUNDIR} | Basedir: ${BASEDIR} "
elif [[ ${PXC} -eq 1 ]]; then
  echoit "Workdir: ${WORKDIR} | Rundir: ${RUNDIR} | Basedir: ${BASEDIR} | PXC Mode: TRUE"
  if [ ${PXC_CLUSTER_RUN} -eq 1 ]; then
    echoit "PXC Cluster run: 'YES'"
  else
    echoit "PXC Cluster run: 'NO'"
  fi
elif [[ ${GRP_RPL} -eq 1 ]]; then
  echoit "Workdir: ${WORKDIR} | Rundir: ${RUNDIR} | Basedir: ${BASEDIR} | Group Replication Mode: TRUE"
  if [ ${GRP_RPL_CLUSTER_RUN} -eq 1 ]; then
    echoit "Group Replication Cluster run: 'YES'"
  else
    echoit "Group Replication Cluster run: 'NO'"
  fi
fi

if [[ ${PXB_CRASH_RUN} -eq 1 ]]; then
  echoit "PXB Base: ${PXB_BASEDIR}"
fi
# Start vault server for pquery encryption run
if [[ $WITH_KEYRING_VAULT -eq 1 ]];then
  echoit "Setting up vault server"
  mkdir $WORKDIR/vault
  rm -rf $WORKDIR/vault/*
  killall vault
  if [[ $PXC -eq 1 ]];then
    ${SCRIPT_PWD}/vault_test_setup.sh --workdir=$WORKDIR/vault --setup-pxc-mount-points --use-ssl
  else
    ${SCRIPT_PWD}/vault_test_setup.sh --workdir=$WORKDIR/vault --use-ssl
    MYEXTRA="$MYEXTRA --early-plugin-load=keyring_vault.so --loose-keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf"
  fi
fi

if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 ]; then
  echoit "mysqld Start Timeout: ${MYSQLD_START_TIMEOUT} | Client Threads: ${THREADS} | Trials: ${TRIALS} | Statements per trial: ${QC_NR_OF_STATEMENTS_PER_TRIAL} | Primary Engine: ${QC_PRI_ENGINE} | Secondary Engine: ${QC_SEC_ENGINE}"
else
  echoit "mysqld Start Timeout: ${MYSQLD_START_TIMEOUT} | Client Threads: ${THREADS} | Queries/Thread: ${QUERIES_PER_THREAD} | Trials: ${TRIALS} | Save coredump/valgrind issue trials only: `if [ ${SAVE_TRIALS_WITH_CORE_OR_VALGRIND_ONLY} -eq 1 ]; then echo -n 'TRUE'; if [ ${SAVE_SQL} -eq 1 ]; then echo ' + save all SQL traces'; else echo ''; fi; else echo 'FALSE'; fi`"
fi
SQL_INPUT_TEXT="SQL file used: ${INFILE}"
if [ ${USE_GENERATOR_INSTEAD_OF_INFILE} -eq 1 ]; then
  if [ ${ADD_INFILE_TO_GENERATED_SQL} -eq 0 ]; then
    SQL_INPUT_TEXT="Using SQL Generator"
  else
    SQL_INPUT_TEXT="Using SQL Generator combined with SQL file ${INFILE}"
  fi
fi
echoit "Valgrind run: `if [ ${VALGRIND_RUN} -eq 1 ]; then echo -n 'TRUE'; else echo -n 'FALSE'; fi` | pquery timeout: ${PQUERY_RUN_TIMEOUT} | ${SQL_INPUT_TEXT} `if [ ${THREADS} -ne 1 ]; then echo -n "| Testcase size (chunked from infile): ${MULTI_THREADED_TESTC_LINES}"; fi`"
echoit "pquery Binary: ${PQUERY_BIN}"
if [ "${MYINIT}" != "" ]; then echoit "MYINIT: ${MYINIT}"; fi
if [ "${MYSAFE}" != "" ]; then echoit "MYSAFE: ${MYSAFE}"; fi
if [ "${MYEXTRA}" != "" ]; then echoit "MYEXTRA: ${MYEXTRA}"; fi
if [ ${QUERY_CORRECTNESS_TESTING} -eq 1 -a "${MYEXTRA2}" != "" ]; then echoit "MYEXTRA2: ${MYEXTRA2}"; fi
echoit "Making a copy of the pquery binary used (${PQUERY_BIN}) to ${WORKDIR}/ (handy for later re-runs/reference etc.)"
cp ${PQUERY_BIN} ${WORKDIR}
echoit "Making a copy of this script (${SCRIPT}) to ${WORKDIR}/ for reference & adding a pquery- prefix (this avoids pquery-prep-run not finding the script)..."  # pquery- prefix avoids pquer-prep-red.sh script-locating issues if this script had been renamed to a name without 'pquery' in it.
cp ${SCRIPT_AND_PATH} ${WORKDIR}/pquery-${SCRIPT}
echoit "Making a copy of the configuration file (${CONFIGURATION_FILE}) to ${WORKDIR}/ for reference & adding a pquery- prefix (this avoids pquery-prep-run not finding the script)..."  # pquery- prefix avoids pquer-prep-red.sh script-locating issues if this script had been renamed to a name without 'pquery' in it.
SHORT_CONFIGURATION_FILE=$(echo ${CONFIGURATION_FILE} | sed 's|.*/[\.]*||')
cp ${SCRIPT_PWD}/${CONFIGURATION_FILE} ${WORKDIR}/pquery-${SHORT_CONFIGURATION_FILE}
if [ ${STORE_COPY_OF_INFILE} -eq 1 ]; then
  echoit "Making a copy of the SQL input file used (${INFILE}) to ${WORKDIR}/ for reference..."
  cp ${INFILE} ${WORKDIR}
fi

# Get version specific options
MID=
if [ -r ${BASEDIR}/scripts/mysql_install_db ]; then MID="${BASEDIR}/scripts/mysql_install_db"; fi
if [ -r ${BASEDIR}/bin/mysql_install_db ]; then MID="${BASEDIR}/bin/mysql_install_db"; fi
START_OPT="--core-file"  # Compatible with 5.6,5.7,8.0
INIT_OPT="--no-defaults --initialize-insecure ${MYINIT}"  # Compatible with 5.7,8.0 (mysqld init)
INIT_TOOL="${BIN}"  # Compatible with 5.7,8.0 (mysqld init), changed to MID later if version <=5.6
VERSION_INFO=$(${BIN} --version | grep -oe '[58]\.[01567]' | head -n1)
if [ "${VERSION_INFO}" == "5.1" -o "${VERSION_INFO}" == "5.5" -o "${VERSION_INFO}" == "5.6" ]; then
  if [ "${MID}" == "" ]; then
    echo "Assert: Version was detected as ${VERSION_INFO}, yet ./scripts/mysql_install_db nor ./bin/mysql_install_db is present!"
    exit 1
  fi
  INIT_TOOL="${MID}"
  INIT_OPT="--no-defaults --force ${MYINIT}"
  START_OPT="--core"
elif [ "${VERSION_INFO}" != "5.7" -a "${VERSION_INFO}" != "8.0" ]; then
  echo "WARNING: mysqld (${BIN}) version detection failed. This is likely caused by using this script with a non-supported distribution or version of mysqld. Please expand this script to handle (which shoud be easy to do). Even so, the scipt will now try and continue as-is, but this may fail."
fi

if [[ ${PXC} -eq 0 && ${GRP_RPL} -eq 0 ]]; then
  echoit "Making a copy of the mysqld used to ${WORKDIR}/mysqld (handy for coredump analysis and manual bundle creation)..."
  mkdir ${WORKDIR}/mysqld
  cp ${BIN} ${WORKDIR}/mysqld
  echoit "Making a copy of the ldd files required for mysqld core analysis to ${WORKDIR}/mysqld..."
  PWDTMPSAVE=$PWD
  cd ${WORKDIR}/mysqld
  ${SCRIPT_PWD}/ldd_files.sh
  cd ${PWDTMPSAVE}
  echoit "Generating datadir template (using mysql_install_db or mysqld --init)..."
  ${INIT_TOOL} ${INIT_OPT} --basedir=${BASEDIR} --datadir=${WORKDIR}/data.template > ${WORKDIR}/log/mysql_install_db.txt 2>&1
  # Sysbench dataload
  if [ ${SYSBENCH_DATALOAD} -eq 1 ]; then
    echoit "Starting mysqld for sysbench data load. Error log is stored at ${WORKDIR}/data.template/master.err"
    CMD="${BIN} --basedir=${BASEDIR} --datadir=${WORKDIR}/data.template --tmpdir=${WORKDIR}/data.template \
      --core-file --port=$PORT --pid_file=${WORKDIR}/data.template/pid.pid --socket=${WORKDIR}/data.template/socket.sock \
      --log-output=none --log-error=${WORKDIR}/data.template/master.err"

    $CMD > ${WORKDIR}/data.template/master.err 2>&1 &
    MPID="$!"

    for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
      sleep 1
      if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/data.template/socket.sock ping > /dev/null 2>&1; then
        break
      fi
      if [ "${MPID}" == "" ]; then
        echoit "Assert! ${MPID} empty. Terminating!"
        exit 1
      fi
    done
    # Sysbench run for data load
    /usr/bin/sysbench --test=${SCRIPT_PWD}/sysbench_scripts/parallel_prepare.lua --num-threads=1 --oltp-tables-count=1 --oltp-table-size=1000000 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${WORKDIR}/data.template/socket.sock run > ${WORKDIR}/data.template/sysbench_prepare.txt 2>&1

    # Terminate mysqld
    timeout --signal=9 20s ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/data.template/socket.sock shutdown > /dev/null 2>&1
    (sleep 0.2; kill -9 ${MPID} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${MPID} >/dev/null 2>&1) &  # Terminate mysqld
  fi
  echo "${MYEXTRA}${MYSAFE}" | if grep -qi "innodb[_-]log[_-]checksum[_-]algorithm"; then
    # Ensure that if MID created log files with the standard checksum algo, whilst we start the server with another one, that log files are re-created by mysqld
    rm ${WORKDIR}/data.template/ib_log*
  fi
  if [ $PMM -eq 1 ];then
    echoit "Initiating PMM configuration"
    if ! docker ps -a | grep 'pmm-data' > /dev/null ; then
      docker create -v /opt/prometheus/data -v /opt/consul-data -v /var/lib/mysql --name pmm-data percona/pmm-server:${PMM_VERSION_CHECK} /bin/true > /dev/null
      check_cmd $? "pmm-server docker creation failed"
    fi
    if ! docker ps -a | grep 'pmm-server' | grep ${PMM_VERSION_CHECK} | grep -v pmm-data > /dev/null ; then
      docker run -d -p 80:80 --volumes-from pmm-data --name pmm-server --restart always percona/pmm-server:${PMM_VERSION_CHECK} > /dev/null
      check_cmd $? "pmm-server container creation failed"
    elif ! docker ps | grep 'pmm-server' | grep ${PMM_VERSION_CHECK} > /dev/null ; then
      docker start pmm-server > /dev/null
      check_cmd $? "pmm-server container not started"
    fi
    if [[ ! -e `which pmm-admin 2> /dev/null` ]] ;then
      echoit "Assert! The pmm-admin client binary was not found, please install the pmm-admin client package"
      exit 1
    else
      PMM_ADMIN_VERSION=`sudo pmm-admin --version`
      if [ "$PMM_ADMIN_VERSION" != "${PMM_VERSION_CHECK}" ]; then
        echoit "Assert! The pmm-admin client version is $PMM_ADMIN_VERSION. Required version is ${PMM_VERSION_CHECK}"
        exit 1
      else
        IP_ADDRESS=`ip route get 8.8.8.8 | head -1 | cut -d' ' -f8`
        sudo pmm-admin config --server $IP_ADDRESS
      fi
    fi
  fi
elif [[ ${PXC} -eq 1 || ${GRP_RPL} -eq 1 ]]; then
  echoit "Making a copy of the mysqld used to ${WORKDIR}/mysqld (handy for coredump analysis and manual bundle creation)..."
  mkdir ${WORKDIR}/mysqld
  cp ${BIN} ${WORKDIR}/mysqld
  echoit "Making a copy of the ldd files required for mysqld core analysis to ${WORKDIR}/mysqld..."
  PWDTMPSAVE=$PWD
  cd ${WORKDIR}/mysqld
  ${SCRIPT_PWD}/ldd_files.sh
  cd ${PWDTMPSAVE}
  if [[ ${PXC} -eq 1 ]] ;then
    echoit "Ensuring PXC templates created for pquery run.."
    pxc_startup startup
    sleep 5
    if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node1.template/node1_socket.sock  ping > /dev/null 2>&1; then
      echoit "PXC node1.template started" ; fi
    if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node2.template/node2_socket.sock  ping > /dev/null 2>&1; then
      echoit "PXC node2.template started" ; fi
    if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node3.template/node3_socket.sock  ping > /dev/null 2>&1; then
      echoit "PXC node3.template started" ;
    else
      echoit "Assert: PXC data template creation failed.."
      exit 1
    fi
    echoit "Created PXC data templates for pquery run.."
    ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node3.template/node3_socket.sock  shutdown > /dev/null 2>&1
    ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node2.template/node2_socket.sock  shutdown > /dev/null 2>&1
    ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node1.template/node1_socket.sock  shutdown > /dev/null 2>&1
  elif [[ ${GRP_RPL} -eq 1 ]] ;then
    echoit "Ensuring Group Replication templates created for pquery run.."
    gr_startup startup
    sleep 5
    if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node1.template/node1_socket.sock  ping > /dev/null 2>&1; then
      echoit "Group Replication node1.template started" ; fi
    if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node2.template/node2_socket.sock  ping > /dev/null 2>&1; then
      echoit "Group Replication node2.template started" ; fi
    if ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node3.template/node3_socket.sock  ping > /dev/null 2>&1; then
      echoit "Group Replication node3.template started" ;
    else
      echoit "Assert: Group Replication data template creation failed.."
      exit 1
    fi
    echoit "Created Group Replication data templates for pquery run.."
    ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node3.template/node3_socket.sock  shutdown > /dev/null 2>&1
    ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node2.template/node2_socket.sock  shutdown > /dev/null 2>&1
    ${BASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node1.template/node1_socket.sock  shutdown > /dev/null 2>&1
  fi
fi

# Start actual pquery testing
echoit "Starting pquery testing iterations..."
COUNT=0
for X in $(seq 1 ${TRIALS}); do
  pquery_test
  COUNT=$[ $COUNT + 1 ]
done
# All done, wrap up pquery run
echoit "pquery finished requested number of trials (${TRIALS})... Terminating..."
if [[ ${PXC} -eq 1 || ${GRP_RPL} -eq 1 ]]; then
  echoit "Cleaning up any leftover processes..."
  KILL_PIDS=`ps -ef | grep "$RANDOMD" | grep -v "grep" | awk '{print $2}' | tr '\n' ' '`
  if [ "${KILL_PIDS}" != "" ]; then
    echoit "Terminating the following PID's: ${KILL_PIDS}"
    kill -9 ${KILL_PIDS} >/dev/null 2>&1
  fi
else
  (ps -ef | grep 'node[0-9]_socket' | grep ${RUNDIR} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true)
  sleep 2; sync
fi
echoit "Done. Attempting to cleanup the pquery rundir ${RUNDIR}..."
rm -Rf ${RUNDIR}
echoit "The results of this run can be found in the workdir ${WORKDIR}..."
echoit "Done. Exiting $0 with exit code 0..."
exit 0
