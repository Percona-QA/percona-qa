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
  SDURATION=300
fi

if [ -z ${SST_METHOD} ]; then
  SST_METHOD=rsync
fi

if [ -z ${TSIZE} ]; then
  TSIZE=5000
fi

if [ -z ${NUMT} ]; then
  NUMT=16
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=100
fi

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

if [[ $SST_METHOD == xtrabackup ]];then
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
mkdir -p $node1
node2="${MYSQL_VARDIR}/node2"
mkdir -p $node2
psnode="${MYSQL_VARDIR}/psnode"
mkdir -p $psnode

echo "Starting PXC node1"
pushd ${PXC_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
    --start-and-exit \
    --port-base=$RBASE1 \
    --nowarnings \
    --vardir=$node1 \
    --mysqld=--skip-performance-schema  \
    --mysqld=--innodb_file_per_table \
    --mysqld=--default-storage-engine=InnoDB \
    --mysqld=--binlog-format=ROW \
    --mysqld=--log-bin \
    --mysqld=--server-id=100 \
    --mysqld=--gtid-mode=ON  \
    --mysqld=--log-slave-updates \
    --mysqld=--enforce-gtid-consistency \
    --mysqld=--wsrep-slave-threads=2 \
    --mysqld=--innodb_autoinc_lock_mode=2 \
    --mysqld=--innodb_locks_unsafe_for_binlog=1 \
    --mysqld=--wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
    --mysqld=--wsrep_cluster_address=gcomm:// \
    --mysqld=--wsrep_sst_receive_address=$RADDR1 \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1" \
    --mysqld=--wsrep_sst_method=$SST_METHOD \
    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
    --mysqld=--wsrep_node_address=$ADDR \
    --mysqld=--innodb_flush_method=O_DIRECT \
    --mysqld=--core-file \
    --mysqld=--loose-new \
    --mysqld=--sql-mode=no_engine_substitution \
    --mysqld=--loose-innodb \
    --mysqld=--secure-file-priv= \
    --mysqld=--loose-innodb-status-file=1 \
    --mysqld=--skip-name-resolve \
    --mysqld=--socket=$WORKDIR/node1.sock \
    --mysqld=--log-error=$WORKDIR/logs/node1.err \
    --mysqld=--log-output=none \
  1st 
set -e
popd

sleep 10

echo "CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$RBASE1, MASTER_USER='root', MASTER_AUTO_POSITION=1;" > $node1/rpl.sql
echo "START SLAVE;" >> $node1/rpl.sql

echo "Sysbench Run: Prepare stage"

$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=$WORKDIR/node1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

pushd ${PXC_BASEDIR}/mysql-test/
export MYSQLD_BOOTSTRAP_CMD=
set +e 
perl mysql-test-run.pl \
    --start-and-exit \
    --port-base=$RBASE2 \
    --nowarnings \
    --vardir=$node2 \
    --mysqld=--skip-performance-schema  \
    --mysqld=--innodb_file_per_table \
    --mysqld=--default-storage-engine=InnoDB \
    --mysqld=--binlog-format=ROW \
    --mysqld=--log-bin \
    --mysqld=--server-id=101 \
    --mysqld=--gtid-mode=ON  \
    --mysqld=--log-slave-updates \
    --mysqld=--enforce-gtid-consistency \
    --mysqld=--wsrep-slave-threads=2 \
    --mysqld=--innodb_autoinc_lock_mode=2 \
    --mysqld=--innodb_locks_unsafe_for_binlog=1 \
    --mysqld=--wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so \
    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1 \
    --mysqld=--wsrep_sst_receive_address=$RADDR2 \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2" \
    --mysqld=--wsrep_sst_method=$SST_METHOD \
    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
    --mysqld=--wsrep_node_address=$ADDR \
    --mysqld=--innodb_flush_method=O_DIRECT \
    --mysqld=--core-file \
    --mysqld=--loose-new \
    --mysqld=--sql-mode=no_engine_substitution \
    --mysqld=--loose-innodb \
    --mysqld=--secure-file-priv= \
    --mysqld=--loose-innodb-status-file=1 \
    --mysqld=--skip-name-resolve \
    --mysqld=--log-error=$WORKDIR/logs/node2.err \
    --mysqld=--socket=$WORKDIR/node2.sock \
    --mysqld=--log-output=none \
1st  
set -e
popd

echo "Sleeping for 10s"
sleep 10

pushd ${PXC_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
    --start-and-exit \
    --port-base=$RBASE3 \
    --nowarnings \
    --vardir=$psnode \
    --mysqld=--innodb_file_per_table \
    --mysqld=--default-storage-engine=InnoDB \
    --mysqld=--binlog-format=ROW \
    --mysqld=--log-bin \
    --mysqld=--server-id=102 \
    --mysqld=--gtid-mode=ON  \
    --mysqld=--log-slave-updates \
    --mysqld=--enforce-gtid-consistency \
    --mysqld=--innodb_flush_method=O_DIRECT \
    --mysqld=--core-file \
    --mysqld=--secure-file-priv= \
    --mysqld=--skip-name-resolve \
    --mysqld=--log-error=$WORKDIR/logs/psnode.err \
    --mysqld=--socket=$WORKDIR/psnode.sock \
    --mysqld=--init-file=$node1/rpl.sql \
    --mysqld=--log-output=none \
1st  
set -e
popd

#OLTP RW run

$SBENCH --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --max-time=$SDURATION --max-requests=1870000000 \
  --test=$LPATH/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=$WORKDIR/node1.sock  run  2>&1 | tee $WORKDIR/logs/sysbench_rw.log

#Creating dsns table for table checkum
echo "drop database if exists percona;create database percona;" | mysql -h${ADDR} -P$RBASE1 -uroot
echo "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100));" | mysql -h${ADDR} -P$RBASE1 -uroot
echo "insert into percona.dsns (id,dsn) values (1,'h=${ADDR},P=$RBASE1,u=root'),(2,'h=${ADDR},P=$RBASE2,u=root'),(3,'h=${ADDR},P=$RBASE3,u=root');" | mysql -h${ADDR} -P$RBASE1 -uroot

SB_MASTER=`mysql -uroot --socket=$WORKDIR/psnode.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
  echo "Slave is not started yet. Please check error log"
  exit 1
fi

while [ $SB_MASTER -gt 0 ]; do
  SB_MASTER=`mysql -uroot --socket=$WORKDIR/psnode.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
  if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
    echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode.err"
    exit 1
  fi
  sleep 5
done

sleep 5

pt-table-checksum h=${ADDR},P=$RBASE1,u=root -d test --recursion-method dsn=h=${ADDR},P=$RBASE1,u=root,D=percona,t=dsns --no-check-binlog-format 

#Shutdown PXC/PS servers

$PXC_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/node1.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/node2.sock -u root shutdown
$PXC_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/psnode.sock -u root shutdown

