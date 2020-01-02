#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test PXC upgrade

# Bash internal configuration
#
set -o nounset    # no undefined variables

# Global variables
declare WORKDIR=""
declare ROOT_FS=""
declare BUILD_NUMBER=""
declare PXC56_BASEDIR=""
declare PXC57_BASEDIR=""
declare PXC80_BASEDIR=""
declare PXC56_BASE=""
declare PXC57_BASE=""
declare PXC80_BASE=""
declare TESTCASE=""
declare SCRIPT_PWD=$(cd `dirname $0` && pwd)
declare MYSQLD_START_TIMEOUT=180
declare MYSQL_VERSION=""
declare SDURATION=""
declare TSIZE=""
declare NUMT=""
declare TCOUNT=""
declare AUTOINC=off
declare DIR=0
declare STEST=oltp
declare SST_METHOD=""
declare LPATH=""
declare EXTSTATUS
declare SYSB_VAR_OPTIONS=""
declare TEST_TYPE=""
declare SYSBENCH_OPTIONS=""
declare MYSQL_VARDIR=""
declare SDIR=""
declare SRESULTS=""
declare ADDR="127.0.0.1"
declare RPORT=$(( (RANDOM%21 + 10)*1000 ))
declare LADDR=""
declare GMCAST_ADDR=""
declare SUSER=root
declare SPASS=""
declare node=""
declare DEBUG=""
declare PXC_MYEXTRA=""

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc-upgrade  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH         Specify work directory"
  echo "  -b, --build-number=NUMBER  Specify work build directory"
  echo "  --56-base                  Specify PXC 5.6 base directory"
  echo "  --57-base                  Specify PXC 5.7 base directory"
  echo "  --80-base                  Specify PXC 8.0 base directory"
  echo "  -t, --testcase=<testcases> Run only following comma-separated list of testcases"
  echo "                                      pxc56topxc57"
  echo "                                      pxc57topxc80"
  echo "                                      pxc56topxc80"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
  echo "  -o, --mysql-extra-options  Specify Mysql extra options used in innodb_options_test"
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
    --57-base )
    PXC57_BASE="$2"
    shift 2
    ;;
    --80-base )
    PXC80_BASE="$2"
    shift 2
    ;;
    -s | --sst-method )
    export SST_METHOD="$2"
    shift 2
    ;;
    -t | --testcase )
    export TESTCASE="$2"
	shift 2
	;;
    -o | --mysql-extra-options )
    MYSQL_EXTRA_OPTIONS="$2"
    shift 2
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

echo "Killing existing mysqld"
ps -ef | grep 'node[0-9].sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

# generic variables
if [[ -z "$WORKDIR" ]]; then
  WORKDIR=${PWD}
fi

if [[ -z "$TESTCASE" ]]; then
  TESTCASE="pxc56topxc80"
else
  if [[ ! $TESTCASE =~ ^(pxc56topxc57|pxc57topxc80|pxc56topxc80)$ ]]; then
    echo "ERROR! Invalid --testcase passed: '$TESTCASE'"
    echo "Please choose one of these testcases: pxc56topxc57, pxc57topxc80, pxc56topxc80"
    exit 1
  fi
fi

if [[ -z "$SST_METHOD" ]]; then
  SST_METHOD="xtrabackup-v2"
else
  if [[ ! $SST_METHOD =~ ^(rsync|xtrabackup-v2)$ ]]; then
    echo "ERROR! Invalid --sst-method passed: '$SST_METHOD'"
    echo "Please choose one of these sst-method: rsync, xtrabackup-v2"
    exit 1
  fi
fi

if [[ -z "${MYSQL_EXTRA_OPTIONS:-}" ]]; then
  MYSQL_EXTRA_OPTIONS="--innodb_file_per_table=ON"
fi

#Format version string (thanks to wsrep_sst_xtrabackup-v2) 
normalize_version(){
  local major=0
  local minor=0
  local patch=0
  
  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  fi
  printf %02d%02d%02d $major $minor $patch
}

#Version comparison script (thanks to wsrep_sst_xtrabackup-v2) 
check_for_version()
{
  local local_version_str="$( normalize_version $1 )"
  local required_version_str="$( normalize_version $2 )"
  
  if [[ "$local_version_str" < "$required_version_str" ]]; then
    return 1
  else
    return 0
  fi
}

ROOT_FS=$WORKDIR

# Table for sysbench oltp rw test
STABLE="test.sbtest1"

if [ ! -d ${ROOT_FS}/test_db ]; then
  pushd ${ROOT_FS}
  git clone https://github.com/datacharmer/test_db.git
  popd
fi

function create_emp_db()
{
  local DB_NAME=$1
  local SE_NAME=$2
  local SQL_FILE=$3
  pushd ${ROOT_FS}/test_db
  cat ${ROOT_FS}/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql
  $PXC56_BASEDIR/bin/mysql --socket=/tmp/node1.socket -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
  popd
}

sysbench_cmd(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

# Parameter of parameterized build
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=100
fi
if [ -z $SDURATION ]; then
  SDURATION=30
fi
if [ -z $AUTOINC ]; then
  AUTOINC=off
fi
if [ -z ${TSIZE} ]; then
  TSIZE=50
fi
if [ -z ${TCOUNT} ]; then
  TCOUNT=5
fi
if [ -z ${NUMT} ]; then
  NUMT=16
fi
if [ -z ${DIR} ]; then
  DIR=0
fi
if [ -z ${STEST} ]; then
  STEST=oltp
fi
if [ -z $SST_METHOD ]; then
  SST_METHOD="rsync"
fi

#Cleanup
if [ -d $WORKDIR/$BUILD_NUMBER ]; then
  rm -r $WORKDIR/$BUILD_NUMBER
fi

if [ "$TESTCASE" == "pxc56topxc57" ] || [ "$TESTCASE" == "pxc56topxc80" ]; then
  if [[ ! -z ${PXC56_BASE} ]];then
    PXC56_BASEDIR=`readlink -e ${PXC56_BASE}* | grep -v ".tar" | head -n1`
  else
    echo "ERROR! Could not find PXC-5.6 binary"
    exit 1
  fi
fi

if [[ ! -z ${PXC57_BASE} ]];then
  PXC57_BASEDIR=`readlink -e ${PXC57_BASE}* | grep -v ".tar" | head -n1`
else
  echo "ERROR! Could not find PXC-5.7 binary"
  exit 1
fi

if [ "$TESTCASE" == "pxc57topxc80" ] || [ "$TESTCASE" == "pxc56topxc80" ]; then
  if [[ ! -z ${PXC80_BASE} ]];then
    PXC80_BASEDIR=`readlink -e ${PXC80_BASE}* | grep -v ".tar" | head -n1`
  else
    echo "ERROR! Could not find PXC-8.0 binary"
    exit 1
  fi
fi

cd $WORKDIR

# User settings
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs
export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

echo "Workdir: $WORKDIR"
echo "Basedirs: "
echo "  $PXC56_BASEDIR"
echo "  $PXC57_BASEDIR"
echo "  $PXC80_BASEDIR"

EXTSTATUS=0

archives() {
  tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz ./${BUILD_NUMBER}/logs || true
}

trap archives EXIT KILL

if [[ $DEBUG -eq 1 ]]; then
  DBG="--mysqld=--wsrep-debug=1"
else
  DBG=""
fi

check_script(){
  local MPID=$1
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID} empty. Terminating!"; exit 1; fi
}

#
# Common functions
#
show_node_status(){
  local FUN_NODE_NR=$1
  local FUN_BASE_DIR=$2
  local SHOW_SYSBENCH_COUNT=$3
  local MYSQL_VERSION=$(${FUN_BASE_DIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
  echo -e "\nShowing status of node${FUN_NODE_NR}:"
  ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global variables like 'version';"
  if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
    ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select * from information_schema.global_status where variable_name like 'wsrep_cluster_size' or variable_name like 'wsrep_cluster_status' or variable_name like 'wsrep_connected' or variable_name like 'wsrep_ready' or variable_name like 'wsrep_local_state_comment';"
  else
     ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select * from performance_schema.global_status where variable_name like 'wsrep_cluster_size' or variable_name like 'wsrep_cluster_status' or variable_name like 'wsrep_connected' or variable_name like 'wsrep_ready' or variable_name like 'wsrep_local_state_comment';" 
  fi
  if [ ${SHOW_SYSBENCH_COUNT} -eq 1 ]; then
    echo "Number of rows in table $STABLE on node${FUN_NODE_NR}"
    ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select count(*) from $STABLE;"
  fi
}

create_cnf(){
  local FUN_BASE_DIR=$1
  local MYSQL_VERSION=$(${FUN_BASE_DIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
  # Creating PXC configuration file
  rm -rf ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "[mysqld]" > ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "basedir=${FUN_BASE_DIR}" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "wsrep-provider=${FUN_BASE_DIR}/lib/libgalera_smm.so" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "wsrep_node_incoming_address=127.0.0.1" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "wsrep_node_address=127.0.0.1" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "innodb_file_per_table" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "innodb_autoinc_lock_mode=2" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  if ! check_for_version $MYSQL_VERSION "8.0.0" ; then
    echo "innodb_locks_unsafe_for_binlog=1" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
    echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  else
    echo "pxc_encrypt_cluster_traffic=OFF" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
    echo "log_error_verbosity=3" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  fi
  echo "innodb_flush_log_at_trx_commit=0" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "innodb_log_file_size=500M" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "wsrep_sst_method=$SST_METHOD" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "log-bin=mysql-bin" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "binlog_format=ROW" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "core-file" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "log-output=none" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
  echo "wsrep_slave_threads=8" >> ${WORKDIR}/pxc_${MYSQL_VERSION}.cnf
}

create_regular_tbl(){
  local FUN_BASE_DIR=$1
  local MYSQL_VERSION=$(${FUN_BASE_DIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
  #
  # Sysbench run on previous version on node1
  #
  ## Prepare/setup
  echo -e "\n\n#### Sysbench prepare run on previous version\n"
  
  sysbench_cmd load_data test
  sysbench $SYSBENCH_OPTIONS --mysql-user=root --mysql-socket=/tmp/node1.socket,/tmp/node2.socket,/tmp/node3.socket prepare > $WORKDIR/logs/sysbench_prepare.txt 2>&1
  #check_script $?
  
  if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
     echo "Sysbench prepare failed"
     exit 1
  fi
  
  echo "Loading sakila test database on node1"
  if check_for_version $MYSQL_VERSION "5.7.0" ; then
    $FUN_BASE_DIR/bin/mysql --socket=/tmp/node1.socket -u root -e "set global pxc_strict_mode=MASTER;" > /dev/null 2>&1
  fi
  $FUN_BASE_DIR/bin/mysql --socket=/tmp/node1.socket -u root < ${SCRIPT_PWD}/../sample_db/sakila.sql
  check_script $?
  
  echo "Loading world test database on node1"
  $FUN_BASE_DIR/bin/mysql --socket=/tmp/node1.socket -u root < ${SCRIPT_PWD}/../sample_db/world.sql
  check_script $?
  
  echo "Loading employees database with innodb engine.."
  create_emp_db employee_1 innodb employees.sql
  check_script $?
}

show_node_status(){
  local FUN_NODE_NR=$1
  local FUN_BASE_DIR=$2
  local SHOW_SYSBENCH_COUNT=$3
  local MYSQL_VERSION=$(${FUN_BASE_DIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
  echo -e "\nShowing status of node${FUN_NODE_NR}:"
  ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global variables like 'version';"
  if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
    ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select * from information_schema.global_status where variable_name like 'wsrep_cluster_size' or variable_name like 'wsrep_cluster_status' or variable_name like 'wsrep_connected' or variable_name like 'wsrep_ready' or variable_name like 'wsrep_local_state_comment';"
  else
     ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select * from performance_schema.global_status where variable_name like 'wsrep_cluster_size' or variable_name like 'wsrep_cluster_status' or variable_name like 'wsrep_connected' or variable_name like 'wsrep_ready' or variable_name like 'wsrep_local_state_comment';" 
  fi
  if [ ${SHOW_SYSBENCH_COUNT} -eq 1 ]; then
    echo "Number of rows in table $STABLE on node${FUN_NODE_NR}"
    ${FUN_BASE_DIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select count(*) from $STABLE;"
  fi
}

pxc_start_node(){
  local FUN_BASE_DIR=$1
  local MYSQL_VERSION=$(${FUN_BASE_DIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
  create_cnf ${FUN_BASE_DIR}

  for i in `seq 1 3`;do
    RBASE="$(( RPORT + ( 100 * $i ) ))"
    LADDR1="127.0.0.1:$(( RBASE + 8 ))"
    if [ ${i} -eq 1 ];then
      WSREP_CLUSTER="gcomm://"
    else
      WSREP_CLUSTER="$WSREP_CLUSTER,gcomm://$LADDR1"
    fi
    node="${MYSQL_VARDIR}/node${i}"
    if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
      ${FUN_BASE_DIR}/scripts/mysql_install_db --no-defaults --basedir=${FUN_BASE_DIR} --datadir=$node  > $WORKDIR/logs/node-${MYSQL_VERSION}-${i}.err 2>&1 || exit 1;
    else
      ${FUN_BASE_DIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${FUN_BASE_DIR} --datadir=$node  > $WORKDIR/logs/node-${MYSQL_VERSION}-${i}.err 2>&1 || exit 1;
    fi  
    echo "Starting PXC-${MYSQL_VERSION} node${i}"
    ${FUN_BASE_DIR}/bin/mysqld --defaults-file=${WORKDIR}/pxc_${MYSQL_VERSION}.cnf \
      --datadir=$node --wsrep_cluster_address=${WSREP_CLUSTER} \
      --wsrep_provider_options=gmcast.listen_addr=tcp://${LADDR1} \
      --log-error=$WORKDIR/logs/node-${MYSQL_VERSION}-${i}.err \
      --socket=/tmp/node${i}.socket \
      --port=${RBASE} --server-id=${i} ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/node-${MYSQL_VERSION}-${i}.err 2>&1 &
    
    for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
      sleep 1
      if $FUN_BASE_DIR/bin/mysqladmin -uroot -S/tmp/node${i}.socket ping > /dev/null 2>&1; then
        break
      fi
    done
    if $FUN_BASE_DIR/bin/mysqladmin -uroot -S/tmp/node${i}.socket ping > /dev/null 2>&1; then
      echo "PXC node${i} started ok.."
      $FUN_BASE_DIR/bin/mysql -uroot -S/tmp/node${i}.socket -e"CREATE DATABASE IF NOT EXISTS test" > /dev/null 2>&1
    else
      echo "PXC node${FUN_NODE_NR} startup failed.. Please check error log: $WORKDIR/logs/node-${MYSQL_VERSION}-${i}.err"
      grep "ERROR" $WORKDIR/logs/node-${MYSQL_VERSION}-${i}.err
      exit 1
    fi
    if [[ ${i} -eq 1 ]];then
      WSREP_CLUSTER="gcomm://$LADDR1"
    fi
  done
}

pxc_upgrade_node(){
  local FUN_NODE_NR=$1
  local FUN_NODE_VER=$2
  local FUN_NODE_PATH=$3
  local FUN_RBASE=$4
  local FUN_LOG_ERR=$5
  local FUN_BASE_DIR=$6

  echo -e "\n\n#### Upgrade node${FUN_NODE_NR} to the version ${FUN_NODE_VER}\n"
  echo "Shutting down node${FUN_NODE_NR} for upgrade"
  ${FUN_BASE_DIR}/bin/mysqladmin  --socket=/tmp/node${FUN_NODE_NR}.socket -u root shutdown
  if [[ $? -ne 0 ]]; then
    echo "Shutdown failed for node${FUN_NODE_NR}"
    exit 1
  fi

  sleep 5

  echo "Starting PXC-${FUN_NODE_VER} node${FUN_NODE_NR} for upgrade"
  ${FUN_BASE_DIR}/bin/mysqld --no-defaults \
    --basedir=${FUN_BASE_DIR} --datadir=${FUN_NODE_PATH} \
    --innodb_file_per_table --innodb_autoinc_lock_mode=2 \
    --wsrep-provider='none' --innodb_flush_method=O_DIRECT \
    --innodb_flush_log_at_trx_commit=0 \
    --innodb_log_file_size=500M \
    --core-file --log_bin --binlog_format=ROW \
    --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${FUN_LOG_ERR} \
    --socket=/tmp/node${FUN_NODE_NR}.socket --log-output=none \
    --port=${FUN_RBASE} --server-id=${FUN_NODE_NR} ${MYSQL_EXTRA_OPTIONS} > ${FUN_LOG_ERR} 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${FUN_BASE_DIR}/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
      break
    fi
  done
  if ${FUN_BASE_DIR}/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
    echo "PXC node${FUN_NODE_NR} re-started for upgrade.."
  else
    echo "PXC node${FUN_NODE_NR} startup for upgrade failed... Please check error log: ${FUN_LOG_ERR}"
    grep "ERROR" ${FUN_LOG_ERR}
    exit 1
  fi

  sleep 10

  # Run mysql_upgrade
  ${FUN_BASE_DIR}/bin/mysql_upgrade -S /tmp/node${FUN_NODE_NR}.socket -u root > $WORKDIR/logs/mysql_upgrade_node${FUN_NODE_NR}.log 2>&1  
  if [[ $? -ne 0 ]]; then
    echo "mysql upgrade on node${FUN_NODE_NR} failed"
    exit 1
  fi

  echo "Shutting down node${FUN_NODE_NR} after upgrade"
  ${FUN_BASE_DIR}/bin/mysqladmin  --socket=/tmp/node${FUN_NODE_NR}.socket -u root shutdown > /dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    echo "Shutdown after upgrade failed for node${FUN_NODE_NR}"
    exit 1
  fi

  sleep 10
}

upgrade_nodes(){
  local FUN_LOWER_BASE_DIR=$1
  local FUN_UPPER_BASE_DIR=$2
  GMCAST_ADDR1=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node1.socket -u root -Bse"select @@wsrep_node_address,@@port + 8" | xargs | sed 's/ /:/g')
  GMCAST_ADDR2=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node2.socket -u root -Bse"select @@wsrep_node_address,@@port + 8" | xargs | sed 's/ /:/g')
  GMCAST_ADDR3=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node3.socket -u root -Bse"select @@wsrep_node_address,@@port + 8" | xargs | sed 's/ /:/g')

  check_startup(){
    SOCKET=$1
    for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
      sleep 1
      if $FUN_UPPER_BASE_DIR/bin/mysqladmin -uroot -S$SOCKET ping > /dev/null 2>&1; then
        break
      fi
    done
  }
  #
  # Upgrading node2 to the new version
  #
  echo -e "\n\n#### Show node2 status before upgrade\n"
  show_node_status 2 $FUN_LOWER_BASE_DIR 0
  LADDR=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node2.socket -u root -Bse "select @@wsrep_cluster_address")
  RBASE=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node2.socket -u root -Bse "select @@port")
  
  local MYSQL_VERSION=$(${FUN_UPPER_BASE_DIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
  create_cnf ${FUN_UPPER_BASE_DIR}
  
  echo "Running upgrade on node2"
  pxc_upgrade_node 2 "$MYSQL_VERSION" "${MYSQL_VARDIR}/node2" "$RBASE" "$WORKDIR/logs/node2-${MYSQL_VERSION}-upgrade.err" "${FUN_UPPER_BASE_DIR}"
  echo "Starting node2 after upgrade"

  ${FUN_UPPER_BASE_DIR}/bin/mysqld --defaults-file=${WORKDIR}/pxc_${MYSQL_VERSION}.cnf \
    --datadir=${MYSQL_VARDIR}/node2 --wsrep_cluster_address=$LADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://${GMCAST_ADDR2} \
    --log-error=$WORKDIR/logs/node-${MYSQL_VERSION}-2.err \
    --socket=/tmp/node2.socket \
    --port=${RBASE} --server-id=2 ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/node-${MYSQL_VERSION}-2.err 2>&1 &
  
  check_startup "/tmp/node2.socket"
  echo -e "\n\n#### Showing nodes status after node2 upgrade and before sysbench\n"

  show_node_status 1 $FUN_LOWER_BASE_DIR 0
  show_node_status 2 $FUN_UPPER_BASE_DIR 0
  show_node_status 3 $FUN_LOWER_BASE_DIR 0
  #
  # End node2 upgrade and check
  #
  sleep 5
  #
  # Upgrading node3 to the new version
  #
  LADDR=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node3.socket -u root -Bse "select @@wsrep_cluster_address")
  RBASE=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node3.socket -u root -Bse "select @@port")
  echo "Running upgrade on node3"
  pxc_upgrade_node 3 "$MYSQL_VERSION" "${MYSQL_VARDIR}/node3" "$RBASE" "$WORKDIR/logs/node3-${MYSQL_VERSION}-upgrade.err" "${FUN_UPPER_BASE_DIR}"
  echo "Starting node3 after upgrade"

  ${FUN_UPPER_BASE_DIR}/bin/mysqld --defaults-file=${WORKDIR}/pxc_${MYSQL_VERSION}.cnf \
    --datadir=${MYSQL_VARDIR}/node3 --wsrep_cluster_address=$LADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://${GMCAST_ADDR3} \
    --log-error=$WORKDIR/logs/node-${MYSQL_VERSION}-3.err \
    --socket=/tmp/node3.socket \
    --port=${RBASE} --server-id=3 ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/node-${MYSQL_VERSION}-3.err 2>&1 &
  
  check_startup "/tmp/node3.socket"
  echo -e "\n\n#### Showing nodes status after node3 upgrade and before sysbench\n"
  show_node_status 1 $FUN_LOWER_BASE_DIR 1
  show_node_status 2 $FUN_UPPER_BASE_DIR 1
  show_node_status 3 $FUN_UPPER_BASE_DIR 1
  
  echo -e "\n\n#### Sysbench OLTP RW run after node3 upgrade\n"
  sysbench_cmd oltp test
  sysbench $SYSBENCH_OPTIONS --mysql-user=root --mysql-socket=/tmp/node3.socket run > $WORKDIR/logs/sysbench_run.txt 2>&1 
  #check_script $?
  
  show_node_status 1 $FUN_LOWER_BASE_DIR 1
  show_node_status 2 $FUN_UPPER_BASE_DIR 1
  show_node_status 3 $FUN_UPPER_BASE_DIR 1
  #
  # End node3 upgrade and check
  #
  sleep 5
  #
  # Upgrading node1 to the new version
  #
  LADDR=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node1.socket -u root -Bse "select @@wsrep_cluster_address")
  RBASE=$(${FUN_LOWER_BASE_DIR}/bin/mysql -S /tmp/node1.socket -u root -Bse "select @@port")
  echo "Running upgrade on node1"
  pxc_upgrade_node 1 "$MYSQL_VERSION" "${MYSQL_VARDIR}/node1" "$RBASE" "$WORKDIR/logs/node1-${MYSQL_VERSION}-upgrade.err" "${FUN_UPPER_BASE_DIR}"
  echo "Starting node1 after upgrade"

  ${FUN_UPPER_BASE_DIR}/bin/mysqld --defaults-file=${WORKDIR}/pxc_${MYSQL_VERSION}.cnf \
    --datadir=${MYSQL_VARDIR}/node1 --wsrep_cluster_address=gcomm://$GMCAST_ADDR2,gcomm://$GMCAST_ADDR3 \
    --wsrep_provider_options=gmcast.listen_addr=tcp://$GMCAST_ADDR1 \
    --log-error=$WORKDIR/logs/node-${MYSQL_VERSION}-1.err \
    --socket=/tmp/node1.socket \
    --port=${RBASE} --server-id=1 ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/node-${MYSQL_VERSION}-1.err 2>&1 &
	
  check_startup "/tmp/node1.socket"
  
  echo -e "\n\n#### Showing nodes status after node1 upgrade and before sysbench\n"
  show_node_status 1 $FUN_UPPER_BASE_DIR 1
  show_node_status 2 $FUN_UPPER_BASE_DIR 1
  show_node_status 3 $FUN_UPPER_BASE_DIR 1
  
  echo -e "\n\n#### Sysbench OLTP RW run after node1 upgrade\n"
  sysbench_cmd oltp test
  sysbench $SYSBENCH_OPTIONS --mysql-user=root --mysql-socket=/tmp/node1.socket run > $WORKDIR/logs/sysbench_run.txt 2>&1 
  #check_script $?
  
  echo -e "\n\n#### Showing nodes status after node1 upgrade and after sysbench\n"
  show_node_status 1 $FUN_UPPER_BASE_DIR 1
  show_node_status 2 $FUN_UPPER_BASE_DIR 1
  show_node_status 3 $FUN_UPPER_BASE_DIR 1
}

upgrade_qa(){
  local FUN_LOWER_BASE_DIR=$1
  local FUN_UPPER_BASE_DIR=$2

  pxc_start_node ${FUN_LOWER_BASE_DIR}
  create_regular_tbl $FUN_LOWER_BASE_DIR
  upgrade_nodes $FUN_LOWER_BASE_DIR $FUN_UPPER_BASE_DIR
  if [[  "$TESTCASE" == "pxc56topxc80" ]]; then
    upgrade_nodes $PXC57_BASEDIR $PXC80_BASEDIR
  fi
}

if [ "$TESTCASE" == "pxc56topxc57" ] || [ "$TESTCASE" == "pxc56topxc80" ]; then
  upgrade_qa $PXC56_BASEDIR $PXC57_BASEDIR
fi
if [[ "$TESTCASE" == "pxc57topxc80" ]]; then
  upgrade_qa $PXC57_BASEDIR $PXC80_BASEDIR
fi 