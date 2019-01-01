#!/bin/bash
# Created by Raghavendra Prabhu
# Updated by Ramesh Sivaraman, Percona LLC
# This will help us to test PXC upgrade

# Bash internal configuration
#
set -o nounset    # no undefined variables

# Global variables
declare WORKDIR=""
declare ROOT_FS=""
declare BUILD_NUMBER=""
declare LOWER_BASEDIR=""
declare UPPER_BASEDIR=""
declare SCRIPT_PWD=$(cd `dirname $0` && pwd)
declare MYSQLD_START_TIMEOUT=180
declare SDURATION=""
declare TSIZE=""
declare NUMT=""
declare TCOUNT=""
declare AUTOINC=off
declare DIR=0
declare STEST=oltp
declare SST_METHOD="rsync"
declare USE_PROXYSQL=0
declare LPATH=""
declare EXTSTATUS
declare SYSB_VAR_OPTIONS=""
declare PROXYSQL_BIN=""
declare TEST_TYPE=""
declare SYSBENCH_OPTIONS=""
declare MYSQL_VARDIR=""
declare SDIR=""
declare SRESULTS=""
declare ADDR="127.0.0.1"
declare RPORT=$(( RANDOM%21 + 10 ))
declare RBASE1=""
declare RADDR1=""
declare LADDR1=""
declare RBASE2=""
declare RADDR2=""
declare LADDR2=""
declare RBASE3=""
declare RADDR3=""
declare LADDR3=""
declare SUSER=root
declare SPASS=""
declare node1=""
declare node2=""
declare node3=""
declare DEBUG=""

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc56to57.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH        Specify work directory"
  echo "  -b, --build-number=NUMBER Specify work build directory"
  echo "  -l, --lower-base          Specify PXC lower base directory"
  echo "  -u, --upper-base          Specify PXC upper base directory"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:l:u:h --longoptions=workdir:,build-number:,lower-base:,upper-base:,help \
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
    -l | --lower-base )
    LOWER_BASE="$2"
    shift 2
    ;;
    -u | --upper-base )
    UPPER_BASE="$2"
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
  $LOWER_BASEDIR/bin/mysql --socket=/tmp/node1.socket -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
  popd
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
if [ -z $USE_PROXYSQL ]; then
  USE_PROXYSQL=0
fi

#Cleanup
if [ -d $WORKDIR/$BUILD_NUMBER ]; then
  rm -r $WORKDIR/$BUILD_NUMBER
fi

# This parameter selects on which nodes the sysbench run will take place
if [ $USE_PROXYSQL -eq 1 ]; then
  SYSB_VAR_OPTIONS="--mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=3306"
elif [ $DIR -eq 0 ]; then
  SYSB_VAR_OPTIONS="--mysql-user=root --mysql-socket=/tmp/node1.socket,/tmp/node2.socket,/tmp/node3.socket"
elif [ $DIR -eq 1 ]; then
  SYSB_VAR_OPTIONS="--mysql-user=root --mysql-socket=/tmp/node1.socket"
elif [ $DIR -eq 2 ]; then
  SYSB_VAR_OPTIONS="--mysql-user=root --mysql-socket=/tmp/node2.socket"
elif [ $DIR -eq 3 ]; then
  SYSB_VAR_OPTIONS="--mysql-user=root --mysql-socket=/tmp/node3.socket"
fi

LOWER_BASEDIR=`readlink -e ${LOWER_BASE}* | grep -v ".tar" | head -n1`
UPPER_BASEDIR=`readlink -e ${UPPER_BASE}* | grep -v ".tar" | head -n1`
LOWER_TAR=`readlink -e ${LOWER_BASE}* | grep ".tar" | head -n1`
UPPER_TAR=`readlink -e ${UPPER_BASE}* | grep ".tar" | head -n1`

if [ ! -z $LOWER_BASEDIR ]; then
  export PATH="$LOWER_BASEDIR/bin:$PATH"
else
  if [ ! -z $LOWER_TAR ];then
    tar -xzf $LOWER_TAR
    LOWER_BASEDIR=`readlink -e ${LOWER_BASE}* | grep -v ".tar" | head -n1`
    export PATH="$LOWER_BASEDIR/bin:$PATH"
  else
    echoit "ERROR! Could not find $LOWER_BASE binary"
    exit 1
  fi
fi

if [ ! -z $UPPER_BASEDIR ]; then
  export PATH="$UPPER_BASEDIR/bin:$PATH"
else
  if [ ! -z $UPPER_TAR ];then
    tar -xzf $UPPER_TAR
    UPPER_BASEDIR=`readlink -e ${UPPER_BASE}* | grep -v ".tar" | head -n1`
    export PATH="$UPPER_BASEDIR/bin:$PATH"
  else
    echoit "ERROR! Could not find $UPPER_BASE binary"
    exit 1
  fi
fi	

cd $WORKDIR

if [ $USE_PROXYSQL -eq 1 ]; then
  PROXYSQL_BIN=$(which proxysql 2>/dev/null)
  if [ -z $PROXYSQL_BIN ]; then
    echo "ProxySQL binary is missing!"
    exit 1
  fi
fi

if [[ ${SST_METHOD} == "xtrabackup" ]]; then
  SST_METHOD="xtrabackup-v2"
  TAR=`ls -1ct percona-xtrabackup*.tar.gz | head -n1`
  tar -xf $TAR
  BBASE="$(tar tf $TAR | head -1 | tr -d '/')"
  export PATH="$ROOT_FS/$BBASE/bin:$PATH"
fi

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

# User settings
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs
export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

SDIR="$LPATH"
SRESULTS="$WORKDIR/sresults"

mkdir -p $SRESULTS

echo "Workdir: $WORKDIR"
echo "Basedirs: $LOWER_BASEDIR $UPPER_BASEDIR"

RBASE1="$(( RPORT*1000 ))"
echo "Setting RBASE to $RBASE1"
RADDR1="$ADDR:$(( RBASE1 + 7 ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"

RBASE2="$(( RBASE1 + 100 ))"
RADDR2="$ADDR:$(( RBASE2 + 7 ))"
LADDR2="$ADDR:$(( RBASE2 + 8 ))"

RBASE3="$(( RBASE2 + 100 ))"
RADDR3="$ADDR:$(( RBASE3 + 7 ))"
LADDR3="$ADDR:$(( RBASE3 + 8 ))"

node1="${MYSQL_VARDIR}/node1"
rm -rf $node1;mkdir -p $node1
node2="${MYSQL_VARDIR}/node2"
rm -rf $node2;mkdir -p $node2
node3="${MYSQL_VARDIR}/node3"
rm -rf $node3;mkdir -p $node3

EXTSTATUS=0

archives() {
  tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz ./${BUILD_NUMBER}/logs || true
  rm -rf $WORKDIR
}

trap archives EXIT KILL

if [[ -n ${EXTERNALS:-} ]]; then
  EXTOPTS="$EXTERNALS"
else
  EXTOPTS=""
fi

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
  local FUN_MYSQL_BASEDIR=$2
  local SHOW_SYSBENCH_COUNT=$3

  echo -e "\nShowing status of node${FUN_NODE_NR}:"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global variables like 'version';"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global status like 'wsrep_cluster_size';"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global status like 'wsrep_cluster_status';"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global status like 'wsrep_connected';"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global status like 'wsrep_ready';"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global status like 'wsrep_local_state_comment';"

  if [ ${SHOW_SYSBENCH_COUNT} -eq 1 ]; then
    echo "Number of rows in table $STABLE on node${FUN_NODE_NR}"
    ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "select count(*) from $STABLE;"
  fi
}

pxc_start_node(){
  local FUN_NODE_NR=$1
  local FUN_NODE_VER=$2
  local FUN_NODE_PATH=$3
  local FUN_CLUSTER_ADDRESS=$4
  local FUN_WSREP_PROVIDER_OPTIONS=$5
  local FUN_RBASE=$6
  local FUN_WSREP_PROVIDER=$7
  local FUN_LOG_ERR=$8
  local FUN_BASE_DIR=$9

  echo "Starting PXC-${FUN_NODE_VER} node${FUN_NODE_NR}"
  ${FUN_BASE_DIR}/bin/mysqld --no-defaults --defaults-group-suffix=.${FUN_NODE_NR} \
    --basedir=${FUN_BASE_DIR} --datadir=${FUN_NODE_PATH} \
    --loose-debug-sync-timeout=600 \
    --innodb_file_per_table --innodb_autoinc_lock_mode=2 \
    --wsrep-provider=${FUN_WSREP_PROVIDER} \
    --wsrep_cluster_address=${FUN_CLUSTER_ADDRESS} \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=${FUN_WSREP_PROVIDER_OPTIONS} \
    --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --query_cache_type=0 --query_cache_size=0 \
    --innodb_flush_log_at_trx_commit=0 \
    --innodb_log_file_size=500M \
    --core-file --log_bin --binlog_format=ROW \
    --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${FUN_LOG_ERR} \
    --socket=/tmp/node${FUN_NODE_NR}.socket --log-output=none \
    --port=${FUN_RBASE} --server-id=${FUN_NODE_NR} --wsrep_slave_threads=8 > ${FUN_LOG_ERR} 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if $FUN_BASE_DIR/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
      break
    fi
  done
  if $FUN_BASE_DIR/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
    echo "PXC node${FUN_NODE_NR} started ok.."
  else
    echo "PXC node${FUN_NODE_NR} startup failed.. Please check error log: ${FUN_LOG_ERR}"
    grep "ERROR" ${FUN_LOG_ERR}
    exit 1
  fi

  sleep 10
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

  sleep 10

  echo "Starting PXC-${FUN_NODE_VER} node${FUN_NODE_NR} for upgrade"
  ${FUN_BASE_DIR}/bin/mysqld --no-defaults --defaults-group-suffix=.${FUN_NODE_NR} \
    --basedir=${FUN_BASE_DIR} --datadir=${FUN_NODE_PATH} \
    --loose-debug-sync-timeout=600 \
    --innodb_file_per_table --innodb_autoinc_lock_mode=2 \
    --wsrep-provider='none' --innodb_flush_method=O_DIRECT \
    --query_cache_type=0 --query_cache_size=0 \
    --innodb_flush_log_at_trx_commit=0 \
    --innodb_log_file_size=500M \
    --core-file --log_bin --binlog_format=ROW \
    --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${FUN_LOG_ERR} \
    --socket=/tmp/node${FUN_NODE_NR}.socket --log-output=none \
    --port=${FUN_RBASE} --server-id=${FUN_NODE_NR} > ${FUN_LOG_ERR} 2>&1 &

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
  ${FUN_BASE_DIR}/bin/mysql_upgrade -S /tmp/node${FUN_NODE_NR}.socket -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade_node${FUN_NODE_NR}.log
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

sysbench_run(){
  local RUN_NAME=$1

  if [[ ! -e $SDIR/${STEST}.lua ]]; then
    pushd /tmp
    rm $STEST.lua || true
    wget -O $STEST.lua https://github.com/Percona-QA/sysbench/tree/0.5/sysbench/tests/db/${STEST}.lua
    SDIR=/tmp/
    popd
  fi

  set -x
  sysbench_cmd oltp test
  sysbench $SYSBENCH_OPTIONS --mysql-ignore-errors=1062,1213 $SYSB_VAR_OPTIONS run 2>&1 | tee $WORKDIR/logs/sysbench_rw_run_${RUN_NAME}.txt
  #check_script $?

  if [[ ${PIPESTATUS[0]} -ne 0 ]];then
    echo "Sysbench run ${RUN_NAME} failed"
    EXTSTATUS=1
  fi
  set +x
}

proxysql_start(){
  $ROOT_FS/$PROXYSQL_BIN --initial -f -c $SCRIPT_PWD/../proxysql.cnf > /dev/null 2>&1 &
  check_script $?
  sleep 10
  ${LOWER_BASEDIR}/bin/mysql -uroot -S/tmp/node1.socket -e"GRANT ALL ON *.* TO 'proxysql'@'localhost' IDENTIFIED BY 'proxysql'"
  ${LOWER_BASEDIR}/bin/mysql -uroot -S/tmp/node1.socket -e"GRANT ALL ON *.* TO 'monitor'@'localhost' IDENTIFIED BY 'monitor'"
  check_script $?
  echo  "INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (0, '127.0.0.1', $RBASE1, 20),(1, '127.0.0.1', $RBASE2, 20),(0, '127.0.0.1', $RBASE3, 20)" | ${LOWER_BASEDIR}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  check_script $?
  echo  "INSERT INTO mysql_users (username, password, active, default_hostgroup, max_connections) VALUES ('proxysql', 'proxysql', 1, 0, 1024)" | ${LOWER_BASEDIR}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  check_script $?
  echo "INSERT INTO mysql_query_rules (active,match_pattern,destination_hostgroup,apply) VALUES(1,'^SELECT',0,1),(1,'^DELETE',0,1),(1,'^UPDATE',1,1),(1,'^INSERT',1,1)" | ${LOWER_BASEDIR}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;LOAD MYSQL QUERY RULES TO RUNTIME;SAVE MYSQL QUERY RULES TO DISK;" | ${LOWER_BASEDIR}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  check_script $?
  sleep 10
}

get_connection_pool(){
  echo -e "ProxySQL connection pool status\n"
  ${LOWER_BASEDIR}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -t -e "select srv_host,srv_port,status,Queries,Bytes_data_sent,Bytes_data_recv from stats_mysql_connection_pool;"
}

#
# Install cluster from previous version
#
echo -e "\n\n#### Installing cluster from previous version\n"
${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR} --datadir=$node1 --force > $WORKDIR/logs/node1-pre.err 2>&1 || exit 1;
pxc_start_node 1 "5.6" "$node1" "gcomm://" "gmcast.listen_addr=tcp://${LADDR1}" "$RBASE1" "${LOWER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node1-pre.err" "${LOWER_BASEDIR}"

${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR} --datadir=$node2 --force > $WORKDIR/logs/node2-pre.err 2>&1 || exit 1;
pxc_start_node 2 "5.6" "$node2" "gcomm://$LADDR1,gcomm://$LADDR3" "gmcast.listen_addr=tcp://${LADDR2}" "$RBASE2" "${LOWER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node2-pre.err" "${LOWER_BASEDIR}"

${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR} --datadir=$node3 --force > $WORKDIR/logs/node3-pre.err 2>&1 || exit 1;
pxc_start_node 3 "5.6" "$node3" "gcomm://$LADDR1,gcomm://$LADDR2" "gmcast.listen_addr=tcp://${LADDR3}" "$RBASE3" "${LOWER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node3-pre.err" "${LOWER_BASEDIR}"

# Start proxysql
if [ $USE_PROXYSQL -eq 1 ]; then
  proxysql_start
fi

#
# Sysbench run on previous version on node1
#
## Prepare/setup
echo -e "\n\n#### Sysbench prepare run on previous version\n"

sysbench_cmd load_data test
sysbench $SYSBENCH_OPTIONS $SYSB_VAR_OPTIONS prepare 2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
#check_script $?

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
   echo "Sysbench prepare failed"
   exit 1
fi

echo "Loading sakila test database on node1"
$LOWER_BASEDIR/bin/mysql --socket=/tmp/node1.socket -u root < ${SCRIPT_PWD}/../sample_db/sakila.sql
check_script $?

echo "Loading world test database on node1"
$LOWER_BASEDIR/bin/mysql --socket=/tmp/node1.socket -u root < ${SCRIPT_PWD}/../sample_db/world.sql
check_script $?

echo "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql
check_script $?

echo "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql
check_script $?

#
# Upgrading node2 to the new version
#
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
echo -e "\n\n#### Show node2 status before upgrade\n"
show_node_status 2 $LOWER_BASEDIR 0
echo "Running upgrade on node2"
pxc_upgrade_node 2 "5.7" "$node2" "$RBASE2" "$WORKDIR/logs/node2-upgrade.err" "${UPPER_BASEDIR}"
echo "Starting node2 after upgrade"
pxc_start_node 2 "5.7" "$node2" "gcomm://$LADDR1,gcomm://$LADDR3" "gmcast.listen_addr=tcp://$LADDR2" "$RBASE2" "${UPPER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node2-after_upgrade.err" "${UPPER_BASEDIR}"

echo -e "\n\n#### Showing nodes status after node2 upgrade and before sysbench\n"
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
show_node_status 1 $LOWER_BASEDIR 0
show_node_status 2 $UPPER_BASEDIR 0
show_node_status 3 $LOWER_BASEDIR 0

echo -e "\n\n#### Sysbench OLTP RW run after node2 upgrade\n"
sysbench_run node2upgrade

echo -e "\n\n#### Showing nodes status after node2 upgrade and after sysbench\n"
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
show_node_status 1 $LOWER_BASEDIR 0
show_node_status 2 $UPPER_BASEDIR 0
show_node_status 3 $LOWER_BASEDIR 0
#
# End node2 upgrade and check
#

sleep 10

#
# Upgrading node3 to the new version
#
echo "Running upgrade on node3"
pxc_upgrade_node 3 "5.7" "$node3" "$RBASE3" "$WORKDIR/logs/node3-upgrade.err" "${UPPER_BASEDIR}"
echo "Starting node3 after upgrade"
pxc_start_node 3 "5.7" "$node3" "gcomm://$LADDR1,gcomm://$LADDR2" "gmcast.listen_addr=tcp://$LADDR3" "$RBASE3" "${UPPER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node3-after_upgrade.err" "${UPPER_BASEDIR}"

echo -e "\n\n#### Showing nodes status after node3 upgrade and before sysbench\n"
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
show_node_status 1 $LOWER_BASEDIR 1
show_node_status 2 $UPPER_BASEDIR 1
show_node_status 3 $UPPER_BASEDIR 1

echo -e "\n\n#### Sysbench OLTP RW run after node3 upgrade\n"
sysbench_run node3upgrade

echo -e "\n\n#### Showing nodes status after node3 upgrade and after sysbench run\n"
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
show_node_status 1 $LOWER_BASEDIR 1
show_node_status 2 $UPPER_BASEDIR 1
show_node_status 3 $UPPER_BASEDIR 1
#
# End node3 upgrade and check
#

sleep 10

#
# Upgrading node1 to the new version
#
echo "Running upgrade on node1"
pxc_upgrade_node 1 "5.7" "$node1" "$RBASE1" "$WORKDIR/logs/node1-upgrade.err" "${UPPER_BASEDIR}"
echo "Starting node1 after upgrade"
pxc_start_node 1 "5.7" "$node1" "gcomm://$LADDR2,gcomm://$LADDR3" "gmcast.listen_addr=tcp://$LADDR1" "$RBASE1" "${UPPER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node1-after_upgrade.err" "${UPPER_BASEDIR}"

echo -e "\n\n#### Showing nodes status after node1 upgrade and before sysbench\n"
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
show_node_status 1 $UPPER_BASEDIR 1
show_node_status 2 $UPPER_BASEDIR 1
show_node_status 3 $UPPER_BASEDIR 1

echo -e "\n\n#### Sysbench OLTP RW run after node1 upgrade\n"
sysbench_run node1upgrade

echo -e "\n\n#### Showing nodes status after node1 upgrade and after sysbench\n"
if [ $USE_PROXYSQL -eq 1 ]; then
  get_connection_pool
fi
show_node_status 1 $UPPER_BASEDIR 1
show_node_status 2 $UPPER_BASEDIR 1
show_node_status 3 $UPPER_BASEDIR 1
#
# End node1 upgrade and check
#

sleep 10

#
# Taking backup for downgrade testing
#
echo -e "\n\n#### Backup before downgrade test\n"
#Workaround for issue 1676401
#$UPPER_BASEDIR/bin/mysql --socket=/tmp/node1.socket -uroot -e "set global show_compatibility_56=1";
$UPPER_BASEDIR/bin/mysqldump --skip-lock-tables --set-gtid-purged=OFF --triggers --routines --socket=/tmp/node1.socket -uroot --databases `$UPPER_BASEDIR/bin/mysql --socket=/tmp/node1.socket -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"` > $WORKDIR/dbdump.sql 2>&1
check_script $?

#
# Downgrade testing
#
echo -e "\n\n#### Downgrade test\n"
$UPPER_BASEDIR/bin/mysqladmin  --socket=/tmp/node1.socket -u root shutdown  > /dev/null 2>&1
$UPPER_BASEDIR/bin/mysqladmin  --socket=/tmp/node2.socket -u root shutdown  > /dev/null 2>&1
$UPPER_BASEDIR/bin/mysqladmin  --socket=/tmp/node3.socket -u root shutdown  > /dev/null 2>&1

rm -Rf $node1/* $node2/* $node3/*

${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR} --datadir=$node1 --force > $WORKDIR/logs/node1-downgrade.err 2>&1 || exit 1;
pxc_start_node 1 "5.6" "$node1" "gcomm://" "gmcast.listen_addr=tcp://${LADDR1}" "$RBASE1" "${LOWER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node1-downgrade.err" "${LOWER_BASEDIR}"

${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR} --datadir=$node2 --force > $WORKDIR/logs/node2-downgrade.err 2>&1 || exit 1;
pxc_start_node 2 "5.6" "$node2" "gcomm://$LADDR1,gcomm://$LADDR3" "gmcast.listen_addr=tcp://${LADDR2}" "$RBASE2" "${LOWER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node2-downgrade.err" "${LOWER_BASEDIR}"

${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR} --datadir=$node3 --force > $WORKDIR/logs/node3-downgrade.err 2>&1 || exit 1;
pxc_start_node 3 "5.6" "$node3" "gcomm://$LADDR1,gcomm://$LADDR2" "gmcast.listen_addr=tcp://${LADDR3}" "$RBASE3" "${LOWER_BASEDIR}/lib/libgalera_smm.so" "$WORKDIR/logs/node3-downgrade.err" "${LOWER_BASEDIR}"

# Import database
${LOWER_BASEDIR}/bin/mysql --socket=/tmp/node1.socket -uroot < $WORKDIR/dbdump.sql 2>&1

CHECK_DBS=`$LOWER_BASEDIR/bin/mysql --socket=/tmp/node1.socket -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"`

echo "Checking table status..."
${LOWER_BASEDIR}/bin/mysqlcheck -uroot --socket=/tmp/node1.socket --check-upgrade --databases $CHECK_DBS 2>&1
check_script $?

echo -e "\n\n#### Showing nodes status after cluster downgrade\n"
show_node_status 1 $LOWER_BASEDIR 1
show_node_status 2 $LOWER_BASEDIR 1
show_node_status 3 $LOWER_BASEDIR 1

$LOWER_BASEDIR/bin/mysqladmin --socket=/tmp/node1.socket -u root shutdown > /dev/null 2>&1
$LOWER_BASEDIR/bin/mysqladmin --socket=/tmp/node2.socket -u root shutdown > /dev/null 2>&1
$LOWER_BASEDIR/bin/mysqladmin --socket=/tmp/node3.socket -u root shutdown > /dev/null 2>&1
if [ $USE_PROXYSQL -eq 1 ]; then
  killall -9 proxysql > /dev/null 2>&1 || true
fi

exit $EXTSTATUS
