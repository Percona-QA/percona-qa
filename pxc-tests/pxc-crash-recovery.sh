#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will help us to test PXC crash recovery

# Bash internal configuration
#
set -o nounset    # no undefined variables

# Global variables
declare WORKDIR=""
declare ROOT_FS=""
declare BUILD_NUMBER=""
declare PXCBASEDIR=""
declare SST_METHOD=""
declare PXCBASEDIR=""
declare MYSQL_VERSION=""
declare ADDR="127.0.0.1"
declare RPORT=$(( (RANDOM%21 + 10)*1000 ))
declare SUSER=root
declare SPASS=
declare PXC_START_TIMEOUT=120
declare PXC_PIDS=""

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "./pxc-crash-recovery.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                     Specify work directory"
  echo "  -b, --build-number=NUMBER              Specify work build directory"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:o:s:t:h --longoptions=workdir:,build-number:,56-base:,57-base:,80-base:,sst-method:,testcase:,mysql-extra-options:,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- "$go_out"
fi

if [[ $go_out == " --" ]];then
  usage
  exit 1
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -w | --workdir )
    WORKDIR="$2"
    if [[ ! -d "$WORKDIR" ]]; then
      echo "ERROR: Workdir ($WORKDIR) directory does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -b | --build-number )
    BUILD_NUMBER="$2"
    shift 2
    ;;
    --56-base )
    PXC56_BASE="$2"
    shift 2
    ;;
    -s | --sst-method )
    export SST_METHOD="$2"
    shift 2
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

# generic variables
if [[ -z "$WORKDIR" ]]; then
  WORKDIR=${PWD}
fi

# Verifying valid SST method for data transfer 
if [[ -z "$SST_METHOD" ]]; then
  SST_METHOD="xtrabackup-v2"
else
  if [[ ! $SST_METHOD =~ ^(rsync|xtrabackup-v2)$ ]]; then
    echo "ERROR! Invalid --sst-method passed: '$SST_METHOD'"
    echo "Please choose one of these sst-method: rsync, xtrabackup-v2"
    exit 1
  fi
fi

# Returns the version string in a standardized format
# Input "1.2.3" => echoes "010203"
# Wrongly formatted values => echoes "000000"
#
# Globals:
#   None
#
# Arguments:
#   Parameter 1: a version string
#                like "5.1.12"
#                anything after the major.minor.revision is ignored
# Outputs:
#   A string that can be used directly with string comparisons.
#   So, the string "5.1.12" is transformed into "050112"
#   Note that individual version numbers can only go up to 99.
#
function normalize_version()
{
  local major=0
  local minor=0
  local patch=0
  
  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([^ ])* ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  fi
  
  printf %02d%02d%02d $major $minor $patch
}

# Compares two version strings
#   The version strings passed in will be normalized to a
#   string-comparable version.
#
# Globals:
#   None
#
# Arguments:
#   Parameter 1: The left-side of the comparison
#   Parameter 2: the comparison operation
#                   '>', '>=', '=', '==', '<', '<='
#   Parameter 3: The right-side of the comparison
#
# Returns:
#   Returns 0 (success) if param1 op param2
#   Returns 1 (failure) otherwise
#
function compare_versions()
{
  local version_1="$( normalize_version $1 )"
  local op=$2
  local version_2="$( normalize_version $3 )"
  
  if [[ ! " = == > >= < <= " =~ " $op " ]]; then
    wsrep_log_error "******************* ERROR ********************** "
    wsrep_log_error "Unknown operation : $op"
    wsrep_log_error "Must be one of : = == > >= < <="
    wsrep_log_error "******************* ERROR ********************** "
    return 1
  fi
  
  [[ $op == "<"  &&   $version_1 <  $version_2 ]] && return 0
  [[ $op == "<=" && ! $version_1 >  $version_2 ]] && return 0
  [[ $op == "="  &&   $version_1 == $version_2 ]] && return 0
  [[ $op == "==" &&   $version_1 == $version_2 ]] && return 0
  [[ $op == ">"  &&   $version_1 >  $version_2 ]] && return 0
  [[ $op == ">=" && ! $version_1 <  $version_2 ]] && return 0
  return 1
}

sysbench_cmd(){
  local TEST_TYPE="$1"
  local DB="$2"
  local THREAD="$3"
  local TIME="$4"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=5000 --oltp_tables_count=$THREAD --mysql-db=$DB --num-threads=$THREAD --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=5000 --oltp_tables_count=$THREAD --max-time=$TIME --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --num-threads=$THREAD --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=5000 --tables=$THREAD --mysql-db=$DB  --threads=$THREAD --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=5000 --tables=$THREAD --mysql-db=$DB --threads=$THREAD --time=$TIME --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

ROOT_FS=$WORKDIR
if [[ -z ${BUILD_NUMBER} ]]; then
  BUILD_NUMBER=1001
fi

cd $ROOT_FS
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs
rm -rf ${WORKDIR}/pxc_crash_recovery.log &> /dev/null
echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/pxc_crash_recovery.log; fi
}

# Killing existing mysqld processes to avoid socket/port conflict
echoit "Killing existing mysqld"
ps -ef | grep 'pxc[0-9].socket' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

#Check PXC base directory
PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
if [[ -z $PXCBASE ]];then
  PXC_TAR=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep ".tar" | head -n1`
  if [[ -z $PXC_TAR ]] ; then
    echoit "ERROR! Could not find PXC base directory or PXC tar ball."
    exit 1
  else
    tar -xzf $PXC_TAR
    PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  fi
fi
PXCBASEDIR="${ROOT_FS}/$PXCBASE"
MYSQL_VERSION=$(${PXCBASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

if [[ $SST_METHOD == "xtrabackup-v2" ]]; then
  #Check PXB base directory
  PXBBASE=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep -v ".tar" | head -n1`
  if [[ -z $PXBBASE ]];then
    PXB_TAR=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep ".tar" | head -n1`
    if [[ -z $PXB_TAR ]] ; then
      echoit "ERROR! Could not find PXB base directory or PXB tar ball."
      exit 1
    else
      tar -xzf $PXB_TAR
      PXBBASE=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep -v ".tar" | head -n1`
    fi
  fi
  if compare_versions $MYSQL_VERSION "<" "8.0.0" ; then
    export PATH="$ROOT_FS/$PXBBASE/bin:$PATH"
  fi
fi

cd ${WORKDIR}

if compare_versions $MYSQL_VERSION ">=" "5.7.0" ; then
  MID="${PXCBASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXCBASEDIR}"
else
  MID="${PXCBASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXCBASEDIR}"
fi

# Creating default ${WORKDIR}/my.cnf file
echo "[mysqld]" > ${WORKDIR}/my.cnf
echo "basedir=${PXCBASEDIR}" >> ${WORKDIR}/my.cnf
echo "innodb_file_per_table" >> ${WORKDIR}/my.cnf
echo "innodb_autoinc_lock_mode=2" >> ${WORKDIR}/my.cnf
echo "wsrep-provider=${PXCBASEDIR}/lib/libgalera_smm.so" >> ${WORKDIR}/my.cnf
echo "wsrep_node_incoming_address=$ADDR" >> ${WORKDIR}/my.cnf
if compare_versions $MYSQL_VERSION "<" "8.0.0" ; then
  echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${WORKDIR}/my.cnf
fi
echo "wsrep_sst_method=$SST_METHOD" >> ${WORKDIR}/my.cnf
echo "wsrep_node_address=$ADDR" >> ${WORKDIR}/my.cnf
echo "core-file" >> ${WORKDIR}/my.cnf
echo "log-output=none" >> ${WORKDIR}/my.cnf
echo "server-id=1" >> ${WORKDIR}/my.cnf
echo "wsrep_slave_threads=2" >> ${WORKDIR}/my.cnf
echo "log-error-verbosity=3" >> ${WORKDIR}/my.cnf

startup_check(){
  local SOCKET=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${PXCBASEDIR}/bin/mysqladmin -uroot -S$SOCKET ping > /dev/null 2>&1; then
      WSREP_STATE=0
      COUNTER=0
      while [[ $WSREP_STATE -ne 4 ]]; do
        WSREP_STATE=$(${PXCBASEDIR}/bin/mysql -uroot -S${SOCKET} -Bse"show status like 'wsrep_local_state'" | awk '{print $2}')
        if [[ $WSREP_STATE -eq 4 ]]; then
          echoit "WSREP: Synchronized with group, ready for connections"
        fi
        let COUNTER=COUNTER+1
        if [[ $COUNTER -eq 50 ]];then
          echoit "WARNING! WSREP: Node is not synchronized with group. Checking slave status"
          break
        fi
        sleep 3
      done
      break
    fi
    if [[ $X -eq ${PXC_START_TIMEOUT} ]]; then
      echoit "ERROR : PXC startup failed. Please check error log."
      exit 1
 	  fi
  done
}
pxc_startup(){
  local MYCNF=$1
  unset PXC_PIDS
  PXC_PIDS=""
  for i in `seq 1 3`;do
    local STARTUP_OPTION="$2"
    local RBASE1="$(( RPORT + ( 100 * $i ) ))"
    local LADDR1="127.0.0.1:$(( RBASE1 + 8 ))"
    if [ $i -eq 1 ];then
      WSREP_CLUSTER="gcomm://"
    else
      WSREP_CLUSTER="$WSREP_CLUSTER,gcomm://$LADDR1"
    fi
    local WSREP_CLUSTER_STRING="$WSREP_CLUSTER"
    echoit "Starting PXC node${i}"
    local node="${WORKDIR}/node${i}"
    rm -rf $node
    if compare_versions $MYSQL_VERSION "<" "5.7.0" ; then
      mkdir -p $node
    fi

    ${MID} --datadir=$node  > ${WORKDIR}/logs/node${i}.err 2>&1 || exit 1;
	sleep 3
	local CMD="${PXCBASEDIR}/bin/mysqld --defaults-file=$MYCNF --datadir=${node} --wsrep_cluster_address=$WSREP_CLUSTER --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 --port=$RBASE1 --log-error=${WORKDIR}/logs/node${i}.err --socket=/tmp/pxc${i}.socket $STARTUP_OPTION"
	echo "$CMD > ${WORKDIR}/logs/node${i}.err 2>&1 &" > ${WORKDIR}/start_node${i}.sh
	chmod 755 ${WORKDIR}/start_node${i}.sh
    $CMD	> ${WORKDIR}/logs/node${i}.err 2>&1 &
    PXC_PIDS+=("$!")
    startup_check "/tmp/pxc${i}.socket"
    if [[ ${i} -eq 1 ]];then
      WSREP_CLUSTER="gcomm://$LADDR1"
    fi
  done
}

test_result(){
  local TEST_NAME=$1
  printf "%-98s\n" | tr " " "="
  printf "%-75s  %-10s  %-10s\n" "TEST" " RESULT" "TIME(s)"
  printf "%-98s\n" | tr " " "-"
  if [ "$TABLE_ROW_COUNT_NODE1" == "$TABLE_ROW_COUNT_NODE3" ]; then
    printf "%-75s  %-10s  %-10s\n" "$TEST_NAME" "[passed]" "$TEST_TIME"
  else
    printf "%-75s  %-10s  %-10s\n" "$TEST_NAME" "[failed]" "$TEST_TIME"
  fi
  printf "%-98s\n" | tr " " "="
}

crash_recovery_test(){
  local TESTNAME="$1"
  local THREAD="$2"
  local TEST_START_TIME=`date '+%s'`
  pxc_startup "${WORKDIR}/my.cnf" ""
  GMCAST_ADDR1=$(${PXCBASEDIR}/bin/mysql -S /tmp/pxc1.socket -u root -Bse"select @@wsrep_node_address,@@port + 8" | xargs | sed 's/ /:/g')
  GMCAST_ADDR2=$(${PXCBASEDIR}/bin/mysql -S /tmp/pxc2.socket -u root -Bse"select @@wsrep_node_address,@@port + 8" | xargs | sed 's/ /:/g')
  GMCAST_ADDR3=$(${PXCBASEDIR}/bin/mysql -S /tmp/pxc3.socket -u root -Bse"select @@wsrep_node_address,@@port + 8" | xargs | sed 's/ /:/g')
  LADDR=$(${PXCBASEDIR}/bin/mysql -S /tmp/pxc3.socket -u root -Bse "select @@wsrep_cluster_address")
  RBASE=$(${PXCBASEDIR}/bin/mysql -S /tmp/pxc3.socket -u root -Bse "select @@port")
  ${PXCBASEDIR}/bin/mysql -S /tmp/pxc1.socket -u root -e"create database if not exists test" 2>&1
  sysbench_cmd load_data test $THREAD ""
  sysbench $SYSBENCH_OPTIONS --mysql-user=root --mysql-socket=/tmp/pxc1.socket,/tmp/pxc2.socket,/tmp/pxc3.socket prepare > $WORKDIR/logs/sysbench_prepare.txt 2>&1
  sysbench_cmd oltp test $THREAD 3000
  local SYSBENCH_OLTP_RUN="sysbench $SYSBENCH_OPTIONS --mysql-user=root --mysql-socket=/tmp/pxc1.socket,/tmp/pxc2.socket,/tmp/pxc3.socket run"
  $SYSBENCH_OLTP_RUN  > $WORKDIR/logs/sysbench_run.txt 2>&1 &
  SPID="$!"
  sleep 10
  if [[ $TESTNAME == "with_force_kill" ]]; then
    echoit "Terminating Node3 for crash recovery"
    kill -9 "${PXC_PIDS[3]}"
    if [[ $THREAD -gt 1 ]]; then	
	  local TEST_DESCRIPTION="Crash recovery with multi thread (using forceful mysqld termination)"
    else
	  local TEST_DESCRIPTION="Crash recovery with single thread (using forceful mysqld termination)"
    fi
  elif [[ $TESTNAME == "single_restart" ]]; then
    echoit "Restarting Node3 for crash recovery"
    ${PXCBASEDIR}/bin/mysqladmin -u root -S /tmp/pxc3.socket shutdown > /dev/null 2>&1
    if [[ $THREAD -gt 1 ]]; then	
	  local TEST_DESCRIPTION="Crash recovery with multi thread (using normal restart)"
    else
	  local TEST_DESCRIPTION="Crash recovery with single thread (using normal restart)"
    fi
  elif [[ $TESTNAME == "multi_restart" ]]; then
    for j in `seq 1 3`;do
      echoit "Restarting Node3 for crash recovery"
      ${PXCBASEDIR}/bin/mysqladmin -u root -S /tmp/pxc3.socket shutdown > /dev/null 2>&1
      ${WORKDIR}/start_node3.sh
      startup_check "/tmp/pxc3.socket"
      if ! ps -p $SPID >/dev/null 2>&1; then
        $SYSBENCH_OLTP_RUN  > $WORKDIR/logs/sysbench_run.txt 2>&1 &
        SPID="$!"
      fi
      sleep 60
	done
    ${PXCBASEDIR}/bin/mysqladmin -u root -S /tmp/pxc3.socket shutdown > /dev/null 2>&1
    if [[ $THREAD -gt 1 ]]; then
	  local TEST_DESCRIPTION="Crash recovery with multi thread (using abnormal restart)"
    else
	  local TEST_DESCRIPTION="Crash recovery with single thread (using abnormal restart)"
    fi
  fi
  if ! ps -p $SPID >/dev/null 2>&1; then
    $SYSBENCH_OLTP_RUN  > $WORKDIR/logs/sysbench_run.txt 2>&1 &
    SPID="$!"
  fi
  sleep 5
  ${WORKDIR}/start_node3.sh
  startup_check "/tmp/pxc3.socket"
  echoit "Terminating sysbench run"
  kill -9 "$SPID"
  sleep 10
  local TABLE_ROW_COUNT_NODE1=`${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.socket -Bse"select count(1) from test.sbtest1"`
  local TABLE_ROW_COUNT_NODE3=`${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/pxc3.socket -Bse"select count(1) from test.sbtest1"`
  local TEST_TIME=$((`date '+%s'` - TEST_START_TIME))
  if  [[ ( -z $TABLE_ROW_COUNT_NODE1 ) &&  (  -z $TABLE_ROW_COUNT_NODE3 ) ]] ;then
    TABLE_ROW_COUNT_NODE1=1;
    TABLE_ROW_COUNT_NODE3=2;
  fi
  test_result "$TEST_DESCRIPTION"
  ${PXCBASEDIR}/bin/mysqladmin -u root -S /tmp/pxc1.socket shutdown > /dev/null 2>&1
  ${PXCBASEDIR}/bin/mysqladmin -u root -S /tmp/pxc2.socket shutdown > /dev/null 2>&1
  ${PXCBASEDIR}/bin/mysqladmin -u root -S /tmp/pxc3.socket shutdown > /dev/null 2>&1
}

crash_recovery_test "with_force_kill" "1"
crash_recovery_test "with_force_kill" "16"
crash_recovery_test "single_restart" "1"
crash_recovery_test "single_restart" "16"
crash_recovery_test "multi_restart" "1"
crash_recovery_test "multi_restart" "16"