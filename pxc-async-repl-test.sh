#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
LPATH="/usr/share/doc/sysbench/tests/db"
PXC_START_TIMEOUT=200

cd $WORKDIR

# For local run - User Configurable Variables

if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

if [ -z ${SDURATION} ]; then
  SDURATION=30
fi

if [ -z ${SST_METHOD} ]; then
  SST_METHOD=rsync
fi

if [ -z ${TSIZE} ]; then
  TSIZE=500
fi

if [ -z ${NUMT} ]; then
  NUMT=16
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=10
fi

#Kill existing mysqld process
ps -ef | grep 'n[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

if [[ $SST_METHOD == xtrabackup ]];then
  SST_METHOD=xtrabackup-v2
  TAR=`ls -1ct percona-xtrabackup*.tar.gz | head -n1`
  tar -xf $TAR
  BBASE=`ls -1td ?ercona-?trabackup* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$BBASE/bin:$PATH"
fi

PXC_TAR=`ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1`

if [ ! -z $PXC_TAR ];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
fi

PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
if [ ! -z $PT_TAR ];then
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
else
  wget https://www.percona.com/downloads/percona-toolkit/2.2.16/tarball/percona-toolkit-2.2.16.tar.gz
  PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
fi

# Keep (PS & QA) builds & results for ~40 days (~1/day)
BUILD_WIPE=$[ ${BUILD_NUMBER} - 40 ]
if [ -d ${BUILD_WIPE} ]; then rm -Rf ${BUILD_WIPE}; fi

# For Sysbench
if [[ "x${Host}" == "xubuntu-trusty-64bit" ]];then
    export CFLAGS="-Wl,--no-undefined -lasan"
fi

if [[ ! -e `which sysbench` ]];then 
    echo "Sysbench not found" 
    exit 1
fi
echo "Note: Using sysbench at $(which sysbench)"


sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"

PXC_BASEDIR="${ROOT_FS}/$PXCBASE"

#mysql install db check

if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXC_BASEDIR}"
fi

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR


mkdir -p $WORKDIR/logs
# User settings
SENDMAIL="/usr/sbin/sendmail"

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE1="$(( RPORT*1000 ))"

echo "Setting RBASE to $RBASE1"
RADDR1="$ADDR:$(( RBASE1 + 7 ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"

RBASE2="$(( RBASE1 + 100 ))"
RBASE3="$(( RBASE2 + 100 ))"
RBASE4="$(( RBASE3 + 100 ))"
RBASE5="$(( RBASE4 + 100 ))"
RBASE6="$(( RBASE5 + 100 ))"

RADDR2="$ADDR:$(( RBASE2 + 7 ))"
LADDR2="$ADDR:$(( RBASE2 + 8 ))"

RADDR3="$ADDR:$(( RBASE3 + 7 ))"
LADDR3="$ADDR:$(( RBASE3 + 8 ))"

SUSER=root
SPASS=

check_script(){
  MPID=$1
  if [ ${MPID} -ne 0 ]; then 
    echo "Assert! ${MPID} empty. Terminating!"; 
    grep "ERROR" ${WORKDIR}/logs/*.err
    exit 1; 
  fi
}

set_pxc_strict_mode(){
  MODE=$1
  $PXC_BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root -e "set global pxc_strict_mode=$MODE"
}

function async_rpl_test(){
  MYEXTRA_CHECK=$1
  node1="${MYSQL_VARDIR}/node1"
  node2="${MYSQL_VARDIR}/node2"
  node3="${MYSQL_VARDIR}/node3"
  psnode1="${MYSQL_VARDIR}/psnode1"
  psnode2="${MYSQL_VARDIR}/psnode2"
  psnode3="${MYSQL_VARDIR}/psnode3"
  rm -Rf $node1  $node2 $node3 $psnode1 $psnode2 $psnode3
  if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
    mkdir -p $node1 $node2 $node3 $psnode1 $psnode2 $psnode3
  fi

  if [ "$MYEXTRA_CHECK" == "GTID" ]; then
    MYEXTRA="--gtid-mode=ON --log-slave-updates --enforce-gtid-consistency"
  fi
  MYEXTRA="$MYEXTRA --binlog-stmt-cache-size=1M"
  function pxc_start(){
    STARTUP_OPTION="$1"
    echo "Starting PXC node1"
    ${MID} --datadir=$node1  > ${WORKDIR}/logs/node1.err 2>&1 || exit 1;
  
    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
      --basedir=${PXC_BASEDIR} $STARTUP_OPTION --datadir=$node1 \
      --loose-debug-sync-timeout=600 --skip-performance-schema \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=100 $MYEXTRA \
      --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
      --wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
      --wsrep_cluster_address=gcomm:// \
      --wsrep_node_incoming_address=$ADDR \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
      --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
      --core-file --loose-new --sql-mode=no_engine_substitution \
      --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
      --log-error=${WORKDIR}/logs/node1.err \
      --socket=/tmp/pxc1.sock --log-output=none \
      --port=$RBASE1 --wsrep_slave_threads=2  \
      --master-info-repository=TABLE --relay-log-info-repository=TABLE > ${WORKDIR}/logs/node1.err 2>&1 &
  
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc1.sock ping > /dev/null 2>&1; then
         break
      fi
    done
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc1.sock ping > /dev/null 2>&1; then
      echo "PXC startup failed.."
      grep "ERROR" ${WORKDIR}/logs/node1.err
    fi
    sleep 10
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show master logs" | awk '{print $1}' | tail -1`

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists test;create database test;"
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      echo "CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE1, MASTER_USER='root', MASTER_AUTO_POSITION=1;" > $node1/rpl.sql
    else
      echo "CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE1, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4;" > $node1/rpl.sql
    fi
    echo "START SLAVE;" >> $node1/rpl.sql
  
    echo "Sysbench Run: Prepare stage"
    sysbench_run load_data test
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

    check_script $?  
    echo "Starting PXC node2"
    ${MID} --datadir=$node2  > ${WORKDIR}/logs/node2.err 2>&1 || exit 1;
  
    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
      --basedir=${PXC_BASEDIR} --datadir=$node2 \
      --loose-debug-sync-timeout=600 --skip-performance-schema \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=101 $MYEXTRA \
      --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
      --wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
      --wsrep_cluster_address=gcomm://$LADDR1 \
      --wsrep_node_incoming_address=$ADDR \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
      --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
      --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
      --core-file --loose-new --sql-mode=no_engine_substitution \
      --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
      --log-error=${WORKDIR}/logs/node2.err \
      --socket=/tmp/pxc2.sock --log-output=none \
      --port=$RBASE2 --wsrep_slave_threads=2 \
      --master-info-repository=TABLE --relay-log-info-repository=TABLE > ${WORKDIR}/logs/node2.err 2>&1 &
  
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc2.sock ping > /dev/null 2>&1; then
         break
      fi
    done
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc2.sock ping > /dev/null 2>&1; then
      echo "PXC startup failed.."
      grep "ERROR" ${WORKDIR}/logs/node2.err
    fi
    sleep 10
    
    echo "Starting PXC node3"
    ${MID} --datadir=$node3  > ${WORKDIR}/logs/node3.err 2>&1 || exit 1;
  
    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
      --basedir=${PXC_BASEDIR} --datadir=$node3 \
      --loose-debug-sync-timeout=600 --skip-performance-schema \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=102 $MYEXTRA \
      --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
      --wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
      --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2 \
      --wsrep_node_incoming_address=$ADDR \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR3 \
      --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
      --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
      --core-file --loose-new --sql-mode=no_engine_substitution \
      --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
      --log-error=${WORKDIR}/logs/node3.err \
      --socket=/tmp/pxc3.sock --log-output=none \
      --port=$RBASE3 --wsrep_slave_threads=2 \
      --master-info-repository=TABLE --relay-log-info-repository=TABLE > ${WORKDIR}/logs/node3.err 2>&1 &
    
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc3.sock ping > /dev/null 2>&1; then
         break
      fi
    done
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc3.sock ping > /dev/null 2>&1; then
      echo "PXC startup failed.."
      grep "ERROR" ${WORKDIR}/logs/node3.err
    fi
  }
  ## Start PXC nodes
  pxc_start
  sleep 10


  function ps_start(){
    STARTUP_OPTION="$1"
    echo "Starting independent PS node1.."
    ${MID} --datadir=$psnode1  > $WORKDIR/logs/psnode1.err 2>&1 || exit 1;
    pushd ${PXC_BASEDIR}/mysql-test/

    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
      --basedir=${PXC_BASEDIR} $STARTUP_OPTION --datadir=$psnode1 \
      --innodb_file_per_table --default-storage-engine=InnoDB \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=103 $MYEXTRA \
      --innodb_flush_method=O_DIRECT --core-file --loose-new \
      --sql-mode=no_engine_substitution --loose-innodb --secure-file-priv= \
      --log-error=$WORKDIR/logs/psnode1.err \
      --socket=/tmp/ps1.sock --init-file=$node1/rpl.sql  --log-output=none \
      --port=$RBASE4 --master-info-repository=TABLE --relay-log-info-repository=TABLE > $WORKDIR/logs/psnode1.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps1.sock ping > /dev/null 2>&1; then
        break
      fi
    done
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps1.sock ping > /dev/null 2>&1; then
      echo "PS startup failed.."
      grep "ERROR" ${WORKDIR}/logs/psnode1.err
    fi
    echo "Starting independent PS node2.."
    ${MID} --datadir=$psnode2  > $WORKDIR/logs/psnode2.err 2>&1 || exit 1;
    pushd ${PXC_BASEDIR}/mysql-test/

    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
      --basedir=${PXC_BASEDIR} $STARTUP_OPTION --datadir=$psnode2 \
      --innodb_file_per_table --default-storage-engine=InnoDB \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=104 $MYEXTRA \
      --innodb_flush_method=O_DIRECT --core-file --loose-new \
      --sql-mode=no_engine_substitution --loose-innodb --secure-file-priv= \
      --log-error=$WORKDIR/logs/psnode2.err \
      --socket=/tmp/ps2.sock  --log-output=none \
      --port=$RBASE5 --master-info-repository=TABLE --relay-log-info-repository=TABLE > $WORKDIR/logs/psnode2.err 2>&1 &
  
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps2.sock ping > /dev/null 2>&1; then
        break
      fi
    done
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps2.sock ping > /dev/null 2>&1; then
      echo "PS startup failed.."
      grep "ERROR" ${WORKDIR}/logs/psnode2.err
    fi

    echo "Starting independent PS node3.."
    ${MID} --datadir=$psnode3  > $WORKDIR/logs/psnode3.err 2>&1 || exit 1;
    pushd ${PXC_BASEDIR}/mysql-test/

    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
      --basedir=${PXC_BASEDIR} $STARTUP_OPTION --datadir=$psnode3 \
      --innodb_file_per_table --default-storage-engine=InnoDB \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=105 $MYEXTRA \
      --innodb_flush_method=O_DIRECT --core-file --loose-new \
      --sql-mode=no_engine_substitution --loose-innodb --secure-file-priv= \
      --log-error=$WORKDIR/logs/psnode3.err \
      --socket=/tmp/ps3.sock  --log-output=none \
      --port=$RBASE6 --master-info-repository=TABLE --relay-log-info-repository=TABLE > $WORKDIR/logs/psnode3.err 2>&1 &
  
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps3.sock ping > /dev/null 2>&1; then
        break
      fi
    done
    if ! ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps3.sock ping > /dev/null 2>&1; then
      echo "PS startup failed.."
      grep "ERROR" ${WORKDIR}/logs/psnode3.err
    fi
    sleep 5
  
    #Creating dsns table for table checkum
    echo "drop database if exists percona;create database percona;" | mysql -h${ADDR} -P$RBASE1 -uroot
    echo "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100),  primary key(id));" | mysql -h${ADDR} -P$RBASE1 -uroot
    echo "insert into percona.dsns (id,dsn) values (1,'h=${ADDR},P=$RBASE1,u=root'),(2,'h=${ADDR},P=$RBASE2,u=root'),(3,'h=${ADDR},P=$RBASE3,u=root');" | mysql -h${ADDR} -P$RBASE1 -uroot
  }

  ## Start PS nodes
  ps_start

  function node1_master_test(){
    echo "******************** $MYEXTRA_CHECK PXC node-1 as master ************************"
    #OLTP RW run
    sysbench_run oltp test
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock run  2>&1 | tee $WORKDIR/logs/sysbench_rw.log

    check_script $?
    SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi 
      sleep 1;
    done

    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi
      sleep 5
    done

    sleep 5
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns \
      --no-check-binlog-format > $WORKDIR/logs/node1_master_checksum.log 2>&1
    check_script $?
    echo -e "\n1 pxc1. PXC node-1 as master: Checksum result.\n"
    cat $WORKDIR/logs/node1_master_checksum.log
    set_pxc_strict_mode ENFORCING
  }

  function node2_master_test(){
    echo "******************** $MYEXTRA_CHECK PXC-node-2 becomes master (take over from node-1) ************************"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"stop slave; reset slave all"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show master logs" | awk '{print $1}' | tail -1`
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE2, MASTER_USER='root', MASTER_AUTO_POSITION=1;"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE2, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4;"
    fi
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"START SLAVE;"

    #OLTP RW run
    sysbench_run oltp test
    $SBENCH $SYSBENCH_OPTIONS --db-driver=mysql --mysql-socket=/tmp/pxc2.sock run  2>&1 | tee $WORKDIR/logs/sysbench_rw.log
    check_script $?

    SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode.err,  $WORKDIR/logs/slave_status_psnode.log"
        exit 1
      fi
      sleep 1;
    done

    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode.err,  $WORKDIR/logs/slave_status_psnode.log"
        exit 1
      fi
      sleep 5
    done

    sleep 5

    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns --no-check-binlog-format > $WORKDIR/logs/node2_master_checksum.log 2>&1
    check_script $?
    echo -e "\n2. pxc2. PXC-node-2 becomes master (took over from node-1): Checksum result.\n"
    cat $WORKDIR/logs/node2_master_checksum.log
    set_pxc_strict_mode ENFORCING
  }

  function node1_slave_test(){
    echo "********************$MYEXTRA_CHECK PXC-as-slave (node-1) from independent master ************************"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show master logs" | awk '{print $1}' | tail -1`
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_AUTO_POSITION=1;"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4;"
    fi
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"START SLAVE;"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"create database if not exists ps_test_1"
    #OLTP RW run
    sysbench_run load_data ps_test_1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
    check_script $?

    SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node1.err,  $WORKDIR/logs/slave_status_node1.log"
        exit 1
      fi
      sleep 1;
    done

    # OLTP RW run
    sysbench_run oltp ps_test_1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock run  2>&1 | tee $WORKDIR/logs/sysbench_ps_rw.log
    check_script $?
    sleep 5
    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node1.err,  $WORKDIR/logs/slave_status_node1.log"
        exit 1
      fi
      sleep 5
    done

    sleep 5
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test,ps_test_1 --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns \
     --no-check-binlog-format > $WORKDIR/logs/node1_slave_checksum.log 2>&1
    check_script $?
    echo -e "\n3. pxc3. PXC-as-slave (node-1) from independent master: Checksum result.\n"
    cat $WORKDIR/logs/node1_slave_checksum.log
    set_pxc_strict_mode ENFORCING
  }

  function node2_slave_test(){
    echo "********************$MYEXTRA_CHECK PXC-as-slave (node-2) from independent master ************************"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show master logs" | awk '{print $1}' | tail -1`
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE6, MASTER_USER='root', MASTER_AUTO_POSITION=1;"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE6, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4;"
    fi
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"START SLAVE;"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"create database if not exists ps_test_2"
    #OLTP RW run
    sysbench_run load_data ps_test_2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
    check_script $?

    SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_node2.log"
        exit 1
      fi
      sleep 1;
    done

    # OLTP RW run
    sysbench_run oltp ps_test_2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock run  2>&1 | tee $WORKDIR/logs/sysbench_ps_rw.log
    check_script $?
    sleep 5
    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_node2.log"
        exit 1
      fi
      sleep 5
    done

    sleep 5
     
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test,ps_test_1,ps_test_2 --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns \
     --no-check-binlog-format > $WORKDIR/logs/node2_slave_checksum.log 2>&1
    check_script $?
    echo -e "\n4. PXC-as-slave (node-2) from independent master: Checksum result.\n"
    cat $WORKDIR/logs/node2_slave_checksum.log
    set_pxc_strict_mode ENFORCING
  }

  function pxc_master_slave_test(){
    echo "********************$MYEXTRA_CHECK PXC - master - and - slave ************************"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show master logs" | awk '{print $1}' | tail -1`

    echo "Sysbench Run for replication master master test : Prepare stage"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e "drop database if exists master_test;create database master_test;"
    sysbench_run load_data master_test
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_ps_prepare.txt
    check_script $?

    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE2, MASTER_USER='root', MASTER_AUTO_POSITION=1;"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE2, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4;"
    fi
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"START SLAVE;"

    #OLTP RW run
    sysbench_run oltp master_test
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc2.sock run  2>&1 | tee $WORKDIR/logs/sysbench_ps_rw.log
    check_script $?

    SB_MASTER=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node1.err,  $WORKDIR/logs/slave_status_node1.log"
        exit 1
      fi
      sleep 1;
    done

    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node1.err,  $WORKDIR/logs/slave_status_node1.log"
        exit 1
      fi
      sleep 5
    done

    sleep 5
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test,ps_test_1,ps_test_2,master_test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns \
     --no-check-binlog-format > $WORKDIR/logs/pxc_master_slave_checksum.log 2>&1
    check_script $?
    echo -e "\n5. PXC - master - and - slave: Checksum result.\n"
    cat  $WORKDIR/logs/pxc_master_slave_checksum.log
    set_pxc_strict_mode ENFORCING
  }

  function pxc_ps_master_slave_shuffle_test(){
    echo "********************$MYEXTRA_CHECK PXC - master - and - slave shuffle test ************************"
    echo "Stopping PXC node1 for shuffle test"
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown > /dev/null 2>&1

    sysbench_run oltp test
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock run  2>&1 | tee $WORKDIR/logs/sysbench_ps_shuffle_rw.log
    check_script $?



    echo "Start PXC node2 for shuffle test"
    ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
      --basedir=${PXC_BASEDIR} --datadir=$node2 \
      --loose-debug-sync-timeout=600 --skip-performance-schema \
      --binlog-format=ROW --log-bin=mysql-bin --server-id=101 $MYEXTRA \
      --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
      --wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
      --wsrep_cluster_address=gcomm://$LADDR1 \
      --wsrep_node_incoming_address=$ADDR \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
      --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
      --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
      --core-file --loose-new --sql-mode=no_engine_substitution \
      --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
      --log-error=${WORKDIR}/logs/node2.err \
      --socket=/tmp/pxc2.sock --log-output=none \
      --port=$RBASE2 --wsrep_slave_threads=2 \
      --master-info-repository=TABLE --relay-log-info-repository=TABLE > ${WORKDIR}/logs/node2.err 2>&1 &
  
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc2.sock ping > /dev/null 2>&1; then
        break
      fi
    done
    sleep 10

    sysbench_run oltp test
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc2.sock run  2>&1 | tee $WORKDIR/logs/sysbench_ps_shuffle_rw.log
    check_script $?

    SB_MASTER=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_node2.log"
        exit 1
      fi
      sleep 1;
    done

    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_node2.log"
        exit 1
      fi
      sleep 5
    done
  
    sleep 5
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns \
      --no-check-binlog-format > $WORKDIR/logs/pxc_master_slave_shuffle_checksum.log 2>&1
    check_script $?
    echo -e "\n6. PXC shuffle master - and - slave : Checksum result.\n"
    cat  $WORKDIR/logs/pxc_master_slave_shuffle_checksum.log
    set_pxc_strict_mode ENFORCING
  }
  
  function pxc_msr_test(){
    echo "********************$MYEXTRA_CHECK PXC - multi source replication test ************************"
    #Shutdown PXC/PS servers for MSR test
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
  
    # Start PXC and PS servers
    rm -Rf $node1  $node2 $node3 $psnode1 $psnode2 $psnode3
    if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
      mkdir -p $node1 $node2 $node3 $psnode1 $psnode2 $psnode3
    fi
    pxc_start
    ps_start
    echo "Sysbench Run for replication master master test : Prepare stage"
  
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc1.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc2.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc3.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/ps1.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/ps2.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/ps3.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"FLUSH LOGS"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"FLUSH LOGS"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE_PS1=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show master logs" | awk '{print $1}' | tail -1`
    MASTER_LOG_FILE_PS2=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show master logs" | awk '{print $1}' | tail -1`
    MASTER_LOG_FILE_PS3=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -Bse "show master logs" | awk '{print $1}' | tail -1`

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists msr_db_master1;create database msr_db_master1;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists msr_db_master2;create database msr_db_master2;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e "drop database if exists msr_db_master3;create database msr_db_master3;"
    sleep 5 
    # Sysbench dataload for MSR test
    sysbench_run load_data msr_db_master1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_msr_db_master1_prepare.txt
    check_script $?
    sysbench_run load_data msr_db_master2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_msr_db_master2_prepare.txt
    check_script $?
    sysbench_run load_data msr_db_master3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_msr_db_master3_prepare.txt

    check_script $?

    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE4, MASTER_USER='root', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master1';"
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master2';"
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE6, MASTER_USER='root', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master3';"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE4, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE_PS1', MASTER_LOG_POS=4  FOR CHANNEL 'master1';"
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE_PS2', MASTER_LOG_POS=4  FOR CHANNEL 'master2';"
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE6, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE_PS3', MASTER_LOG_POS=4  FOR CHANNEL 'master3';"
    fi

#    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE4, MASTER_USER='root', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master1';"
#    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master2';"
#    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE6, MASTER_USER='root', MASTER_AUTO_POSITION=1 FOR CHANNEL 'master3';"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"START SLAVE;"

    sysbench_run oltp msr_db_master1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  2>&1 | tee $WORKDIR/logs/sysbench_ps_channel1_rw.log
    check_script $?
    sysbench_run oltp msr_db_master2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  2>&1 | tee $WORKDIR/logs/sysbench_ps_channel2_rw.log
    check_script $?
    sysbench_run oltp msr_db_master3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock  run  2>&1 | tee $WORKDIR/logs/sysbench_ps_channel3_rw.log
    check_script $?
    sleep 10
    SB_CHANNEL1=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master1'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL2=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master2'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL3=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
  
    if ! [[ "$SB_CHANNEL1" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL2" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi
    
    while [ $SB_CHANNEL3 -gt 0 ]; do
      SB_CHANNEL3=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
        echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
        exit 1
      fi
      sleep 5
    done
    sleep 5
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d msr_db_master1,msr_db_master2,msr_db_master3 --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns --no-check-binlog-format > $WORKDIR/logs/pxc_msr_checksum.log 2>&1
    check_script $?
    echo -e "\n7. PXC - multi source replication: Checksum result.\n"
    cat  $WORKDIR/logs/pxc_msr_checksum.log
    set_pxc_strict_mode ENFORCING
  }
  
  function pxc_mtr_test(){
    echo "********************$MYEXTRA_CHECK PXC - multi thread replication test ************************"
    #Shutdown PXC/PS servers for MSR test
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
  
    # Start PXC and PS servers
    rm -Rf $node1  $node2 $node3 $psnode1 $psnode2 $psnode3
    if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
      mkdir -p $node1 $node2 $node3 $psnode1 $psnode2 $psnode3
    fi
    EXTRA="--slave-parallel-workers=5"
    pxc_start $EXTRA
    ps_start $EXTRA
    echo "Sysbench Run for replication master master test : Prepare stage"
  
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc1.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc2.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc3.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/ps1.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/ps2.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true
    $PXC_BASEDIR/bin/mysql  --socket=/tmp/ps3.sock -u root -e "STOP SLAVE; RESET SLAVE ALL" || true

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"FLUSH LOGS"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"FLUSH LOGS"
    MASTER_LOG_FILE_N1=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show master logs" | awk '{print $1}' | tail -1`
    MASTER_LOG_FILE_PS2=`${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show master logs" | awk '{print $1}' | tail -1`

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc1;create database mtr_db_pxc1;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc2;create database mtr_db_pxc2;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc3;create database mtr_db_pxc3;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc4;create database mtr_db_pxc4;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc5;create database mtr_db_pxc5;"
  
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps1;create database mtr_db_ps1;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2;create database mtr_db_ps2;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps3;create database mtr_db_ps3;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps4;create database mtr_db_ps4;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps5;create database mtr_db_ps5;"
  
    # Sysbench dataload for MTR test
    sysbench_run load_data mtr_db_pxc1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_pxc1_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_pxc2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_pxc2_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_pxc3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_pxc3_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_pxc4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_pxc4_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_pxc5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_pxc5_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_ps1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_ps1_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_ps2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_ps2_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_ps3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_ps3_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_ps4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_ps4_prepare.txt
    check_script $?
    sysbench_run load_data mtr_db_ps5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_mtr_db_ps5_prepare.txt
    check_script $?
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE1, MASTER_USER='root', MASTER_AUTO_POSITION=1;"
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_AUTO_POSITION=1;"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE1, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE_N1', MASTER_LOG_POS=4;"
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE5, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE_PS2', MASTER_LOG_POS=4;"
    fi
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"START SLAVE;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e"START SLAVE;"
 

    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_pxc1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc1_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_pxc2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc2_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_pxc3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc3_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_pxc4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc4_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_pxc5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc5_rw.log 2>&1 &
    check_script $?
    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_ps1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_ps2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_ps3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps3_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_ps4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps4_rw.log 2>&1 &
    check_script $?
    sysbench_run oltp mtr_db_ps5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps5_rw.log 2>&1 &
    check_script $?
    sleep 10
    SB_PS=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_PXC=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    if ! [[ "$SB_PXC" =~ ^[0-9]+$ ]]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node2.log
      echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_node2.log"
      exit 1
    fi
    if ! [[ "$SB_PS" =~ ^[0-9]+$ ]]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
      echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
      exit 1
    fi
    while [ $SB_PXC -gt 0 ]; do
      SB_PXC=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PXC" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_node2.log"
        exit 1
      fi
      sleep 5
    done

    while [ $SB_PS -gt 0 ]; do
      SB_PS=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PS" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi
      sleep 5
    done

    sleep 5
    set_pxc_strict_mode DISABLED
    pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d mtr_db_pxc1,mtr_db_pxc2,mtr_db_pxc3,mtr_db_pxc4,mtr_db_pxc5,mtr_db_ps1,mtr_db_ps2,mtr_db_ps3,mtr_db_ps4,mtr_db_ps5 --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns --no-check-binlog-format > $WORKDIR/logs/pxc_mtr_checksum.log 2>&1
    check_script $?
    echo -e "\n8. PXC - multi thread replication: Checksum result.\n"
    cat  $WORKDIR/logs/pxc_mtr_checksum.log
    set_pxc_strict_mode ENFORCING
  }

  node1_master_test
  node2_master_test
  node1_slave_test
  node2_slave_test
  pxc_master_slave_test
  pxc_ps_master_slave_shuffle_test
  pxc_msr_test
  pxc_mtr_test
}

echo "**************** ASYNC REPLICATION TEST RUN WITH GTID ***************"
async_rpl_test GTID

#Shutdown PXC/PS servers
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown

echo "**************** ASYNC REPLICATION TEST RUN WITHOUT GTID ***************"
async_rpl_test 


#Shutdown PXC/PS servers
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown

