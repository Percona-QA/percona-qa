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

#Kill proxysql process
killall -9 proxysql > /dev/null 2>&1 || true

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

PS_TAR=`ls -1td ?ercona-?erver* | grep ".tar" | head -n1`

if [ ! -z $PS_TAR ];then
  tar -xzf $PS_TAR
  PS_BASE=`ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PS_BASE/bin:$PATH"
fi
PSBASE="$ROOT_FS/$PS_BASE"
if [ ! -e $ROOT_FS/garbd ];then
  wget http://jenkins.percona.com/job/pxc56.buildandtest.galera3/Btype=release,label_exp=centos6-64/lastSuccessfulBuild/artifact/garbd
  cp garbd $ROOT_FS/$PXCBASE/bin/
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
fi

if [[ ! -e `which proxysql` ]];then 
  echo "proxysql not found" 
  exit 1
else
  PROXYSQL=`which proxysql`
fi

check_script(){
  MPID=$1
  if [ ${MPID} -eq 1 ]; then echo "Assert! ${MPID} empty. Terminating!"; exit 1; fi
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
    --log-error=${WORKDIR}/logs/node2.err \
    --socket=/tmp/node2.sock --log-output=none \
    --port=$RBASE2 --server-id=2 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node2.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node2.sock ping > /dev/null 2>&1; then
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
}

proxysql_startup(){
  $PROXYSQL --initial -f -c $SCRIPT_PWD/proxysql.cnf > /dev/null 2>&1 &
  check_script $?
  sleep 10
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "GRANT ALL ON *.* TO 'proxysql'@'%' IDENTIFIED BY 'proxysql'"
  echo  "INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (0, '127.0.0.1', $RBASE1, 20),(0, '127.0.0.1', $RBASE2, 20),(0, '127.0.0.1', $RBASE3, 20)" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  echo  "INSERT INTO mysql_users (username, password, active, default_hostgroup, max_connections) VALUES ('proxysql', 'proxysql', 1, 0, 200)" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin 
  echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin 
}

#PXC startup
pxc_startup
#ProxySQL startup
proxysql_startup
check_script $?

#Sysbench data load
$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE \
  --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1  --num-threads=$NUMT --db-driver=mysql \
  prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

check_script $?

#Shutdown PXC servers
$BASEDIR/bin/mysqladmin  --socket=/tmp/node1.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node2.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node3.sock -u root shutdown

