#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
LPATH="/usr/share/doc/sysbench/tests/db"

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

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"

PXC_BASEDIR="${ROOT_FS}/$PXCBASE"

#mysql install db check

if [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --basedir=${PXC_BASEDIR}"
fi

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR


mkdir -p $WORKDIR/logs
# User settings
SENDMAIL="/usr/sbin/sendmail"

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE1="$(( RPORT*1000 ))"
#lsof -i tcp:$RBASE1 |  awk 'NR!=1 {print $2}'  |  xargs kill -9 2>/dev/null
echo "Setting RBASE to $RBASE1"
RADDR1="$ADDR:$(( RBASE1 + 7 ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"

RBASE2="$(( RBASE1 + 100 ))"
RBASE3="$(( RBASE2 + 100 ))"
#lsof -i tcp:$RBASE2 |  awk 'NR!=1 {print $2}'  |  xargs kill -9 2>/dev/null
RADDR2="$ADDR:$(( RBASE2 + 7 ))"
LADDR2="$ADDR:$(( RBASE2 + 8 ))"

SUSER=root
SPASS=

node1="${MYSQL_VARDIR}/node1"
node2="${MYSQL_VARDIR}/node2"
psnode="${MYSQL_VARDIR}/psnode"
rm -Rf $node1  $node2 $psnode
mkdir -p $node1 $node2 $psnode

echo "Starting PXC node1"
${MID} --datadir=$node1  > ${WORKDIR}/logs/node1.err 2>&1 || exit 1;

${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
  --basedir=${PXC_BASEDIR} --datadir=$node1 \
  --loose-debug-sync-timeout=600 --skip-performance-schema \
  --binlog-format=ROW --log-bin --server-id=100 --gtid-mode=ON  \
  --log-slave-updates --enforce-gtid-consistency \
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
  --socket=/tmp/n1.sock --log-output=none \
  --port=$RBASE1 --wsrep_slave_threads=2  > ${WORKDIR}/logs/node1.err 2>&1 &

echo "Waiting for node-1 to start ....."
MPID="$!"
while true ; do
  sleep 10
  if egrep -qi  "Synchronized with group, ready for connections" ${WORKDIR}/logs/node1.err ; then
   break
  fi
  if [ "${MPID}" == "" ]; then
    echoit "Error! server not started.. Terminating!"
    egrep -i "ERROR|ASSERTION" ${WORKDIR}/logs/node1.err
    exit 1
  fi
done

sleep 10

${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/n1.sock -e "drop database if exists test;create database test;"

echo "CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE1, MASTER_USER='root', MASTER_AUTO_POSITION=1;" > $node1/rpl.sql
echo "START SLAVE;" >> $node1/rpl.sql

echo "Sysbench Run: Prepare stage"

$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=/tmp/n1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

echo "Starting PXC node2"
${MID} --datadir=$node2  > ${WORKDIR}/logs/node2.err 2>&1 || exit 1;

${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
  --basedir=${PXC_BASEDIR} --datadir=$node2 \
  --loose-debug-sync-timeout=600 --skip-performance-schema \
  --binlog-format=ROW --log-bin --server-id=101 --gtid-mode=ON  \
  --log-slave-updates --enforce-gtid-consistency \
  --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
  --wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
  --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR3 \
  --wsrep_node_incoming_address=$ADDR \
  --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
  --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
  --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
  --core-file --loose-new --sql-mode=no_engine_substitution \
  --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
  --log-error=${WORKDIR}/logs/node2.err \
  --socket=/tmp/n2.sock --log-output=none \
  --port=$RBASE2 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node2.err 2>&1 &

echo "Waiting for node-2 to start ....."
MPID="$!"
while true ; do
  sleep 10
  if egrep -qi  "Synchronized with group, ready for connections" ${WORKDIR}/logs/node2.err ; then
    break
  fi
  if [ "${MPID}" == "" ]; then
    echoit "Error! server not started.. Terminating!"
    egrep -i "ERROR|ASSERTION" ${WORKDIR}/logs/node2.err
    exit 1
  fi
done

sleep 10

#Creating dsns table for table checkum
echo "drop database if exists percona;create database percona;" | mysql -h${ADDR} -P$RBASE1 -uroot
echo "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100));" | mysql -h${ADDR} -P$RBASE1 -uroot
echo "insert into percona.dsns (id,dsn) values (1,'h=${ADDR},P=$RBASE1,u=root'),(2,'h=${ADDR},P=$RBASE2,u=root'),(3,'h=${ADDR},P=$RBASE3,u=root');" | mysql -h${ADDR} -P$RBASE1 -uroot

function master_slave_test(){

  echo "Starting PS slave.."
  ${MID} --datadir=$psnode  > $WORKDIR/logs/psnode.err 2>&1 || exit 1;
  pushd ${PXC_BASEDIR}/mysql-test/

  ${PXC_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
    --basedir=${PXC_BASEDIR} --datadir=$psnode \
    --innodb_file_per_table --default-storage-engine=InnoDB \
    --binlog-format=ROW --log-bin --server-id=102 \
    --gtid-mode=ON  --log-slave-updates \
    --enforce-gtid-consistency --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= \
    --log-error=$WORKDIR/logs/psnode.err \
    --socket=/tmp/n3.sock --init-file=$node1/rpl.sql  --log-output=none \
    --port=$RBASE3 > $WORKDIR/logs/psnode.err 2>&1 &
  
  #OLTP RW run

  $SBENCH --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --max-time=$SDURATION --max-requests=1870000000 \
    --test=$LPATH/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=/tmp/n1.sock run  2>&1 | tee $WORKDIR/logs/sysbench_rw.log

  SB_MASTER=`mysql -uroot --socket=/tmp/n3.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

  if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
    echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode.err"
    exit 1
  fi

  while [ $SB_MASTER -gt 0 ]; do
    SB_MASTER=`mysql -uroot --socket=/tmp/n3.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode.err"
      exit 1
    fi
    sleep 5
  done

  sleep 5

  pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns --no-check-binlog-format > $WORKDIR/logs/master_slave_checksum.log 2>&1
}

function master_master_test(){
  echo "Sysbench Run for replication master master test : Prepare stage"

  ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/n3.sock -e "drop database if exists master_test;create database master_test;"
  $SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=master_test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=/tmp/n3.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_ps_prepare.txt

  echo "CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE3, MASTER_USER='root', MASTER_AUTO_POSITION=1;" | $PXC_BASEDIR/bin/mysql -h${ADDR} -P$RBASE1 -uroot 
  echo "START SLAVE;" |  $PXC_BASEDIR/bin/mysql -h${ADDR} -P$RBASE1 -uroot

  #OLTP RW run

  $SBENCH --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --max-time=$SDURATION --max-requests=1870000000 \
    --test=$LPATH/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --mysql-db=master_test --mysql-user=root --db-driver=mysql --mysql-socket=/tmp/n3.sock  run  2>&1 | tee $WORKDIR/logs/sysbench_ps_rw.log

  SB_MASTER=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

  if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
    echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
    exit 1
  fi

  while [ $SB_MASTER -gt 0 ]; do
    SB_MASTER=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi
    sleep 5
  done

  sleep 5

  pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d master_test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns --no-check-binlog-format > $WORKDIR/logs/master_master_checksum.log 2>&1
}

master_slave_test
master_master_test

#Checksum result.
echo -e "Replication master slave table checksum result.\n"
cat $WORKDIR/logs/master_slave_checksum.log
echo -e "\nReplication master master table checksum result.\n"
cat  $WORKDIR/logs/master_master_checksum.log

#Shutdown PXC/PS servers
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/n1.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/n2.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/n3.sock -u root shutdown

