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
  SDURATION=30
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

PXC_TAR=`ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1`

if [ ! -z $PXC_TAR ];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
fi

if [ ! -a $ROOT_FS/garbd ];then
  wget http://jenkins.percona.com/job/pxc56.buildandtest.galera3/Btype=release,label_exp=centos6-32/lastSuccessfulBuild/artifact/garbd
  cp garbd $ROOT_FS/$PXCBASE/bin/
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
fi

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

GARBDP="$(( LADDR3 + 100 ))"

SUSER=root
SPASS=

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
BASEDIR="${ROOT_FS}/$PXCBASE"
mkdir -p $WORKDIR  $WORKDIR/logs


pxc_startup(){
  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
    MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
  elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
    MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
  fi
  node1="${WORKDIR}/node1"
  node2="${WORKDIR}/node2"
  node3="${WORKDIR}/node3"

  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
    mkdir -p $node1 $node2 $node3
  fi

  ${MID} --datadir=$node1  > ${WORKDIR}/startup_node1.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
    --basedir=${BASEDIR} --datadir=$node1 \
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
    --log-error=$node1/node1.err \
    --socket=$node1/node1_socket.sock --log-output=none \
    --port=$RBASE1 --server-id=1 --wsrep_slave_threads=2 > $node1/node1.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node1/node1_socket.sock ping > /dev/null 2>&1; then
      break
    fi
  done
  
  ${MID} --datadir=$node2  > ${WORKDIR}/startup_node2.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
    --basedir=${BASEDIR} --datadir=$node2 \
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
    --log-error=$node2/node2.err \
    --socket=$node2/node2_socket.sock --log-output=none \
    --port=$RBASE2 --server-id=2 --wsrep_slave_threads=2 > $node2/node2.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node2/node2_socket.sock ping > /dev/null 2>&1; then
      break
    fi
  done

  ${MID} --datadir=$node3  > ${WORKDIR}/startup_node3.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.3 \
    --basedir=${BASEDIR} --datadir=$node3 \
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
    --log-error=$node3/node3.err \
    --socket=$node3/node3_socket.sock --log-output=none \
    --port=$RBASE3 --server-id=3 --wsrep_slave_threads=2 > $node3/node3.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$node3/node3_socket.sock ping > /dev/null 2>&1; then
      ${BASEDIR}/bin/mysql -uroot -S$node1/node1_socket.sock -e "create database if not exists test" > /dev/null 2>&1
      sleep 2
      break
    fi
  done
}

garbd_run(){
  #Sysbench data load
  $SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE \
    --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql \
    --mysql-socket=$node1/node1_socket.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

  $ROOT_FS/garbd --address gcomm://$LADDR1,$LADDR2,$LADDR3 --group "my_wsrep_cluster" --options "gmcast.listen_addr=tcp://$GARBDP" --log /tmp/garbd.log --daemon

  #OLTP RW run
  $SBENCH --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --max-time=$SDURATION --max-requests=1870000000 \
    --test=$LPATH/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 \
    --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root --db-driver=mysql \
    --mysql-socket=$node1/node1_socket.sock run  2>&1 | tee $WORKDIR/logs/sysbench_rw.log

  #Shutdown PXC servers
  $BASEDIR/bin/mysqladmin  --socket=$node1/node1_socket.sock -u root shutdown
  $BASEDIR/bin/mysqladmin  --socket=$node2/node2_socket.sock -u root shutdown
  $BASEDIR/bin/mysqladmin  --socket=$node3/node3_socket.sock -u root shutdown
}

pxc_startup
garbd_run
