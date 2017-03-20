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

# For local run - User Configurable Variables
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi
if [ -z ${SDURATION} ]; then
  SDURATION=60
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

#Kill garbd process
killall -9 garbd > /dev/null 2>&1 || true

#Kill existing mysqld process
ps -ef | grep 'n[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 > /dev/null 2>&1 || true

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL
cd $ROOT_FS

PXC_TAR=`ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1`

if [ ! -z $PXC_TAR ];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
fi

if [ ! -e $ROOT_FS/garbd ];then
  wget http://jenkins.percona.com/job/pxc56.buildandtest.galera3/Btype=release,label_exp=centos6-64/lastSuccessfulBuild/artifact/garbd
  cp garbd $ROOT_FS/$PXCBASE/bin/
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
fi
check_script(){
  MPID=$1
  if [ ${MPID} -ne 0  ]; then echo "Assert! ${MPID} empty. Terminating!"; exit 1; fi
}

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
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql"
    fi
  fi
}

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE1="$(( RPORT*1000 ))"
RADDR1="$ADDR:$(( RBASE1 + 7 ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"
RBASE2="$(( RBASE1 + 100 ))"
RADDR2="$ADDR:$(( RBASE2 + 7 ))"
LADDR2="$ADDR:$(( RBASE2 + 8 ))"  
RBASE3="$(( RBASE1 + 200 ))"
RADDR3="$ADDR:$(( RBASE3 + 7 ))"
LADDR3="$ADDR:$(( RBASE3 + 8 ))"
RBASE4="$(( RBASE1 + 300 ))"
RADDR4="$ADDR:$(( RBASE4 + 7 ))"
LADDR4="$ADDR:$(( RBASE4 + 8 ))"
RBASE5="$(( RBASE1 + 400 ))"
RADDR5="$ADDR:$(( RBASE5 + 7 ))"
LADDR5="$ADDR:$(( RBASE5 + 8 ))"

GARBDBASE="$(( RBASE1 + 500 ))"
GARBDP="$ADDR:$GARBDBASE"

SUSER=root
SPASS=

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
BASEDIR="${ROOT_FS}/$PXCBASE"
mkdir -p $WORKDIR  $WORKDIR/logs

pxc_add_nodes(){
  node_count=$1
  if [ $node_count -eq 3 ]; then
    if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node3.sock ping > /dev/null 2>&1; then
      echo "PXC node3 already started.. "
    else
      ${MID} --datadir=$node3  > ${WORKDIR}/startup_node3.err 2>&1 || exit 1;
      ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.3 \
        --basedir=${BASEDIR} --datadir=$node3 --max-connections=2048 \
        --loose-debug-sync-timeout=600 --skip-performance-schema \
        --innodb_file_per_table $PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
        --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
        --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2 \
        --wsrep_node_incoming_address=$ADDR \
        --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR3 \
        --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
        --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
        --core-file --loose-new --sql-mode=no_engine_substitution \
        --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
        --log-error=${WORKDIR}/logs/node3.err \
        --socket=/tmp/node3.sock --log-output=none \
        --port=$RBASE3 --server-id=3 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node3.err 2>&1 &

      for X in $(seq 0 ${PXC_START_TIMEOUT}); do
        sleep 1
        if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node3.sock ping > /dev/null 2>&1; then
          ${BASEDIR}/bin/mysql -uroot -S/tmp/node1.sock -e "create database if not exists test" > /dev/null 2>&1
          sleep 2
          break
        fi
      done
   fi
  fi
  if [ $node_count -eq 4 ]; then
    if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node4.sock ping > /dev/null 2>&1; then
      echo "PXC node4 already started.. "
    else
      ${MID} --datadir=$node4  > ${WORKDIR}/startup_node4.err 2>&1 || exit 1;
      ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.3 \
        --basedir=${BASEDIR} --datadir=$node4 --max-connections=2048 \
        --loose-debug-sync-timeout=600 --skip-performance-schema \
        --innodb_file_per_table $PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
        --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
        --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 \
        --wsrep_node_incoming_address=$ADDR \
        --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR4 \
        --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
        --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
        --core-file --loose-new --sql-mode=no_engine_substitution \
        --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
        --log-error=${WORKDIR}/logs/node4.err \
        --socket=/tmp/node4.sock --log-output=none \
        --port=$RBASE4 --server-id=4 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node4.err 2>&1 &

      for X in $(seq 0 ${PXC_START_TIMEOUT}); do
        sleep 1
        if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node4.sock ping > /dev/null 2>&1; then
          sleep 2
          break
        fi
      done
    fi
  fi
  if [ $node_count -eq 5 ]; then
    if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node5.sock ping > /dev/null 2>&1; then
      echo "PXC node5 already started.. "
    else
      ${MID} --datadir=$node5  > ${WORKDIR}/startup_node5.err 2>&1 || exit 1;
      ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.3 \
        --basedir=${BASEDIR} --datadir=$node5 --max-connections=2048 \
        --loose-debug-sync-timeout=600 --skip-performance-schema \
        --innodb_file_per_table $PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
        --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
        --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3,gcomm://$LADDR4 \
        --wsrep_node_incoming_address=$ADDR \
        --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR5 \
        --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
        --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
        --core-file --loose-new --sql-mode=no_engine_substitution \
        --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
        --log-error=${WORKDIR}/logs/node5.err \
        --socket=/tmp/node5.sock --log-output=none \
        --port=$RBASE5 --server-id=5 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node5.err 2>&1 &

      for X in $(seq 0 ${PXC_START_TIMEOUT}); do
        sleep 1
        if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node5.sock ping > /dev/null 2>&1; then
          sleep 2
          break
        fi
      done
    fi
  fi
}

pxc_startup(){
  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
    MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
  elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
    MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
  fi
  node1="${WORKDIR}/node1"
  node2="${WORKDIR}/node2"
  node3="${WORKDIR}/node3"
  node4="${WORKDIR}/node4"
  node5="${WORKDIR}/node5"

  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
    mkdir -p $node1 $node2 $node3 $node4 $node5
  fi
  ${MID} --datadir=$node1  > ${WORKDIR}/startup_node1.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
    --basedir=${BASEDIR} --datadir=$node1 --max-connections=2048 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm:// \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${WORKDIR}/logs/node1.err \
    --socket=/tmp/node1.sock --log-output=none \
    --port=$RBASE1 --server-id=1 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node1.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node1.sock ping > /dev/null 2>&1; then
      ${BASEDIR}/bin/mysql -uroot --socket=/tmp/node1.sock -e "drop database if exists test;create database test;"
      break
    fi
  done
  

  ${MID} --datadir=$node2  > ${WORKDIR}/startup_node2.err 2>&1 || exit 1;
  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
    --basedir=${BASEDIR} --datadir=$node2 --max-connections=2048 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR3 \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${WORKDIR}/logs/node2.err \
    --socket=/tmp/node2.sock --log-output=none \
    --port=$RBASE2 --server-id=2 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node2.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node2.sock ping > /dev/null 2>&1; then
      break
    fi
  done
  #Sysbench data load
  sysbench_run load_data test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/node1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
  check_script $?
  
  $ROOT_FS/garbd --address gcomm://$LADDR1,$LADDR2,$LADDR3 --group "my_wsrep_cluster" --options "gmcast.listen_addr=tcp://$GARBDP" --log /tmp/garbd.log --daemon
  check_script $?
}

pxc_startup

garbd_run(){
  pxc_add_nodes $1
  #OLTP RW run
  sysbench_run oltp test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/node1.sock run  2>&1 | tee $WORKDIR/logs/sysbench_rw.log
  check_script $?
}

garbd_run 3
garbd_run 4
garbd_run 5

#Shutdown PXC servers
$BASEDIR/bin/mysqladmin  --socket=/tmp/node1.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node2.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node3.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node4.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node5.sock -u root shutdown

