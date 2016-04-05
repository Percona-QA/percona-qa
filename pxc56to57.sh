#!/bin/bash 
# Created by Raghavendra Prabhu <raghavendra.prabhu@percona.com>
# Updated by Ramesh Sivaraman, Percona LLC

ulimit -c unlimited
export MTR_MAX_SAVE_CORE=5

set +e
echo "Killing existing mysqld"
pgrep -f mysqld

pkill -f mysqld
sleep 10
pgrep mysqld || pkill -9 -f mysqld

sleep 5
SCRIPT_PWD=$(cd `dirname $0` && pwd)
WORKDIR=$1
ROOT_FS=$WORKDIR
MYSQLD_START_TIMEOUT=180

if [ ! -d ${ROOT_FS}/test_db ]; then
  git clone https://github.com/datacharmer/test_db.git
fi

function create_emp_db()
{
  DB_NAME=$1
  SE_NAME=$2
  SQL_FILE=$3
  pushd ${ROOT_FS}/test_db
  cat ${ROOT_FS}/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql
   $BASEDIR/bin/mysql --socket=/tmp/node1.socket -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

# Parameter of parameterized build
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

if [ -z $SDURATION ];then
  SDURATION=30
fi
if [ -z $THREEONLY ];then
  THREEONLY=0
fi
if [ -z $AUTOINC ];then
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
  DIR=1
fi
if [ -z ${STEST} ]; then
  STEST=oltp
fi

if [ -z $SST_METHOD ];then
  SST_METHOD="rsync"
fi

cd $WORKDIR

sst_method=$SST_METHOD

if [[ $sst_method == xtrabackup ]];then
  sst_method="xtrabackup-v2"
  TAR=`ls -1ct percona-xtrabackup*.tar.gz | head -n1`
  tar -xf $TAR
  BBASE="$(tar tf $TAR | head -1 | tr -d '/')"
  export PATH="$ROOT_FS/$BBASE/bin:$PATH"
fi

count=$(ls -1ct Percona-XtraDB-Cluster-5.7*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then 
  for dirs in `ls -1ct Percona-XtraDB-Cluster-5.7*.tar.gz | tail -n +2`;do 
     rm -rf $dirs
  done 
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.7*' -exec rm -rf {} \+

count=$(ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then 
  for dirs in `ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | tail -n +2`;do 
    rm -rf $dirs
  done 
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.6*' -exec rm -rf {} \+


echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | head -n1`
BASE1="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR

TAR=`ls -1ct Percona-XtraDB-Cluster-5.7*.tar.gz | head -n1`
BASE2="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR


LPATH=${SPATH:-/usr/share/doc/sysbench/tests/db}

# User settings
SENDMAIL="/usr/sbin/sendmail"


WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

MYSQL_BASEDIR1="${ROOT_FS}/$BASE1"
MYSQL_BASEDIR2="${ROOT_FS}/$BASE2"
export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

SDIR="$LPATH"
SRESULTS="$WORKDIR/sresults"

mkdir -p $SRESULTS

echo "Workdir: $WORKDIR"
echo "Basedirs: $MYSQL_BASEDIR1 $MYSQL_BASEDIR2"

#if [[ $THREEONLY -eq 1 ]];then 
    GALERA2="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
    GALERA3="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
#else
#    GALERA2="${MYSQL_BASEDIR1}/lib/galera2/libgalera_smm.so"
#    GALERA3="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
#fi


ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE1="$(( RPORT*1000 ))"
echo "Setting RBASE to $RBASE1"
RADDR1="$ADDR:$(( RBASE1 + 7 ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"

RBASE2="$(( RBASE1 + 100 ))"
RADDR2="$ADDR:$(( RBASE2 + 7 ))"
LADDR2="$ADDR:$(( RBASE2 + 8 ))"

SUSER=root
SPASS=

node1="${MYSQL_VARDIR}/node1"
rm -rf $node1;mkdir -p $node1
node2="${MYSQL_VARDIR}/node2"
rm -rf $node2;mkdir -p $node2

EXTSTATUS=0

if [[ $MEM -eq 1 ]];then 
  MEMOPT="--mem"
else 
  MEMOPT=""
fi

archives() {
    tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz ./${BUILD_NUMBER}/logs || true
    rm -rf $WORKDIR
}

trap archives EXIT KILL

if [[ -n ${EXTERNALS:-} ]];then 
  EXTOPTS="$EXTERNALS"
else
  EXTOPTS=""
fi

if [[ $DEBUG -eq 1 ]];then 
  DBG="--mysqld=--wsrep-debug=1"
else 
  DBG=""
fi

echo "Starting 5.6 node"

echo "Starting PXC-5.6 node1"
 ${MYSQL_BASEDIR1}/scripts/mysql_install_db  --basedir=${MYSQL_BASEDIR1} \
  --datadir=$node1 2>&1 || exit 1;

${MYSQL_BASEDIR1}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
  --basedir=${MYSQL_BASEDIR1} --datadir=$node1 \
  --loose-debug-sync-timeout=${MYSQLD_START_TIMEOUT}0 --default-storage-engine=InnoDB \
  --default-tmp-storage-engine=InnoDB --skip-performance-schema \
  --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
  --wsrep-provider=${MYSQL_BASEDIR1}/lib/libgalera_smm.so \
  --wsrep_cluster_address=gcomm:// \
  --wsrep_sst_receive_address=$RADDR1 --wsrep_node_incoming_address=$ADDR \
  --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
  --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
  --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
  --query_cache_type=0 --query_cache_size=0 \
  --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
  --innodb_log_file_size=500M --skip-external-locking \
  --core-file --loose-new --sql-mode=no_engine_substitution \
  --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
  --skip-name-resolve --log-error=$WORKDIR/logs/node1.err \
  --socket=/tmp/node1.socket --log-output=none \
  --port=$RBASE1 --skip-grant-tables \
  --server-id=1 --wsrep_slave_threads=8 --wsrep_debug=OFF  > $WORKDIR/logs/node1.err 2>&1 &

for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  if $MYSQL_BASEDIR1/bin/mysqladmin -uroot -S/tmp/node1.socket ping > /dev/null 2>&1; then
    break
  fi
done

if $MYSQL_BASEDIR1/bin/mysqladmin -uroot -S/tmp/node1.socket ping > /dev/null 2>&1; then
  echo "PXC node1 started ok.."
else
  echo "PXC node1 startup failed.. Please check error log : $WORKDIR/logs/node1.err"
fi

sleep 10
# Sysbench Runs
## Prepare/setup
echo "Sysbench Run: Prepare stage"

sysbench --test=$SDIR/parallel_prepare.lua --report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-engine-trx=yes --mysql-table-engine=innodb \
    --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root \
    --db-driver=mysql --mysql-socket=/tmp/node1.socket prepare 2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt 

if [[ ${PIPESTATUS[0]} -ne 0 ]];then 
   echo "Sysbench prepare failed"
   exit 1
fi

echo "Loading sakila test database"
$MYSQL_BASEDIR1/bin/mysql --socket=/tmp/node1.socket -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echo "Loading world test database"
$MYSQL_BASEDIR1/bin/mysql --socket=/tmp/node1.socket -u root < ${SCRIPT_PWD}/sample_db/world.sql

echo "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql

echo "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql


$MYSQL_BASEDIR1/bin/mysql  -S /tmp/node1.socket -u root -e "create database testdb;" || true

${MYSQL_BASEDIR1}/scripts/mysql_install_db  --basedir=${MYSQL_BASEDIR1} \
  --datadir=$node2 2>&1 || exit 1;

${MYSQL_BASEDIR1}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
  --basedir=${MYSQL_BASEDIR1} --datadir=$node2 \
  --loose-debug-sync-timeout=${MYSQLD_START_TIMEOUT}0 --default-storage-engine=InnoDB \
  --default-tmp-storage-engine=InnoDB --skip-performance-schema \
  --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
  --wsrep-provider=${MYSQL_BASEDIR1}/lib/libgalera_smm.so \
  --wsrep_cluster_address=gcomm://$LADDR1 \
  --wsrep_sst_receive_address=$RADDR2 --wsrep_node_incoming_address=$ADDR \
  --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
  --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
  --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
  --query_cache_type=0 --query_cache_size=0 \
  --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
  --innodb_log_file_size=500M --skip-external-locking \
  --core-file --loose-new --sql-mode=no_engine_substitution \
  --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
  --skip-name-resolve --log-error=$WORKDIR/logs/node2-pre.err \
  --socket=/tmp/node2.socket --log-output=none \
  --port=$RBASE2 --skip-grant-tables \
  --server-id=2 --wsrep_slave_threads=8 > $WORKDIR/logs/node2-pre.err 2>&1 &

for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  if $MYSQL_BASEDIR1/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
    break
  fi
done
if $MYSQL_BASEDIR1/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
  echo "PXC node2 started ok.."
else
  echo "PXC node2 startup failed.. Please check error log : $WORKDIR/logs/node2-pre.err"
fi

sleep 10
echo "Version of second node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "show global variables like 'version';"

echo "Shutting down node2 after SST"
${MYSQL_BASEDIR1}/bin/mysqladmin  --socket=/tmp/node2.socket -u root shutdown
if [[ $? -ne 0 ]];then 
   echo "Shutdown failed for node2" 
   exit 1
fi

popd
    
sleep 10

pushd ${MYSQL_BASEDIR2}/mysql-test/
export MYSQLD_BOOTSTRAP_CMD=

echo "Running for upgrade"

${MYSQL_BASEDIR2}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
  --basedir=${MYSQL_BASEDIR2} --datadir=$node2 \
  --loose-debug-sync-timeout=${MYSQLD_START_TIMEOUT}0 --default-storage-engine=InnoDB \
  --default-tmp-storage-engine=InnoDB --skip-performance-schema \
  --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
  --wsrep-provider='none' --innodb_flush_method=O_DIRECT \
  --query_cache_type=0 --query_cache_size=0 \
  --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
  --innodb_log_file_size=500M --skip-external-locking \
  --core-file --loose-new --sql-mode=no_engine_substitution \
  --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
  --skip-name-resolve --log-error=$WORKDIR/logs/node2-upgrade.err \
  --socket=/tmp/node2.socket --log-output=none --skip-grant-tables  > $WORKDIR/logs/node2-upgrade.err 2>&1 &

for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  if $MYSQL_BASEDIR2/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
    break
  fi
done
if $MYSQL_BASEDIR2/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
  echo "PXC node2 re-started for upgrade.."
else
  echo "PXC node2 startup failed.. Please check error log : $WORKDIR/logs/node2-upgrade.err"
fi

sleep 10
$MYSQL_BASEDIR2/bin/mysql_upgrade -S /tmp/node2.socket -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

if [[ $? -ne 0 ]];then 
  echo "mysql upgrade failed"
  exit 1
fi

echo "Version of second node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "show global variables like 'version';"

echo "Shutting down node2 after upgrade"
$MYSQL_BASEDIR2/bin/mysqladmin  --socket=/tmp/node2.socket -u root shutdown > /dev/null 2>&1

if [[ $? -ne 0 ]];then 
  echo "Shutdown failed for node2" 
  exit 1
fi

sleep 10

if [[ $THREEONLY -eq 0 ]];then 
  echo "Starting again with compat options"

${MYSQL_BASEDIR2}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
  --basedir=${MYSQL_BASEDIR2} --datadir=$node2 \
  --loose-debug-sync-timeout=${MYSQLD_START_TIMEOUT}0 --default-storage-engine=InnoDB \
  --default-tmp-storage-engine=InnoDB --skip-performance-schema \
  --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
  --wsrep-provider=$GALERA3 --binlog-format=ROW \
  --wsrep_cluster_address=gcomm://$LADDR1 \
  --wsrep_sst_receive_address=$RADDR2 --wsrep_node_incoming_address=$ADDR \
  --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2; socket.checksum=1" \
  --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
  --log_bin_use_v1_row_events=1 --gtid_mode=0 --binlog_checksum=NONE \
  --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
  --query_cache_type=0 --query_cache_size=0 \
  --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
  --innodb_log_file_size=500M --skip-external-locking \
  --core-file --loose-new --sql-mode=no_engine_substitution \
  --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
  --skip-name-resolve --log-error=$WORKDIR/logs/node2-post.err \
  --socket=/tmp/node2.socket --log-output=none \
  --port=$RBASE2 --skip-grant-tables \
  --server-id=2 --wsrep_slave_threads=8 > $WORKDIR/logs/node2-post.err 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if $MYSQL_BASEDIR2/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
      break
    fi
  done
  if $MYSQL_BASEDIR2/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
    echo "PXC node2 re-started for post upgrade check.."
  else
    echo "PXC node2 startup failed.. Please check error log : $WORKDIR/logs/node2-post.err"
  fi
  sleep 10
else 
  echo "Starting node again without compat"

 ${MYSQL_BASEDIR2}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
  --basedir=${MYSQL_BASEDIR2} --datadir=$node2 \
  --loose-debug-sync-timeout=${MYSQLD_START_TIMEOUT}0 --default-storage-engine=InnoDB \
  --default-tmp-storage-engine=InnoDB --skip-performance-schema \
  --innodb_file_per_table --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
  --wsrep-provider=$GALERA3 --binlog-format=ROW \
  --wsrep_cluster_address=gcomm://$LADDR1 \
  --wsrep_sst_receive_address=$RADDR2 --wsrep_node_incoming_address=$ADDR \
  --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
  --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
  --log_bin_use_v1_row_events=1 --gtid_mode=0 --binlog_checksum=NONE \
  --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
  --query_cache_type=0 --query_cache_size=0 \
  --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
  --innodb_log_file_size=500M --skip-external-locking \
  --core-file --loose-new --sql-mode=no_engine_substitution \
  --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
  --skip-name-resolve --log-error=$WORKDIR/logs/node2-post.err \
  --socket=/tmp/node2.socket --log-output=none \
  --port=$RBASE2 --skip-grant-tables \
  --server-id=2 --wsrep_slave_threads=8 > $WORKDIR/logs/node2-post.err 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if $MYSQL_BASEDIR2/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
      break
    fi
  done
  if $MYSQL_BASEDIR2/bin/mysqladmin -uroot -S/tmp/node2.socket ping > /dev/null 2>&1; then
    echo "PXC node2 re-started for post upgrade check.."
  else
    echo "PXC node2 startup failed.. Please check error log : $WORKDIR/logs/node2-post.err"
  fi
  sleep 10
fi

popd

echo "Version of second node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "show global variables like 'version';"

echo "Sleeping for 10s"
sleep 10


STABLE="test.sbtest1" 

echo "Before RW testing"
echo "Rows on node1" 
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "select count(*) from $STABLE;"
echo "Rows on node2" 
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "select count(*) from $STABLE;"

echo "Version of first node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "show global variables like 'version';"
echo "Version of second node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "show global variables like 'version';"

if [[ ! -e $SDIR/${STEST}.lua ]];then 
  pushd /tmp
  rm $STEST.lua || true
  wget -O $STEST.lua  https://github.com/Percona-QA/sysbench/tree/0.5/sysbench/tests/db/${STEST}.lua
  SDIR=/tmp/
  popd
fi

set -x

$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "create database testdb;" || true

if [[ $DIR -eq 1 ]];then 
  sockets="/tmp/node1.socket,/tmp/node2.socket"
elif [[ $DIR -eq 2 ]];then 
  sockets="/tmp/node2.socket"
elif [[ $DIR -eq 3 ]];then 
  sockets="/tmp/node1.socket"
fi

## OLTP RW Run
echo "Sysbench Run: OLTP RW testing"
sysbench --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --oltp-auto-inc=$AUTOINC --max-time=$SDURATION --max-requests=1870000000 \
    --test=$SDIR/$STEST.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=100 --mysql-db=test \
    --mysql-user=root --db-driver=mysql --mysql-socket=$sockets \
    run 2>&1 | tee $WORKDIR/logs/sysbench_rw_run.txt 

if [[ ${PIPESTATUS[0]} -ne 0 ]];then 
  echo "Sysbench run failed"
  EXTSTATUS=1
fi

set +x


echo "Version of first node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "show global variables like 'version';"
echo "Version of second node:"
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "show global variables like 'version';"
  
echo "Rows on node1" 
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "select count(*) from $STABLE;"
echo "Rows on node2" 
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node2.socket  -u root -e "select count(*) from $STABLE;"

$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "drop database testdb;" || true
$MYSQL_BASEDIR1/bin/mysql -S /tmp/node1.socket  -u root -e "drop database test;"

$MYSQL_BASEDIR1/bin/mysqladmin  --socket=/tmp/node1.socket -u root shutdown  > /dev/null 2>&1
$MYSQL_BASEDIR2/bin/mysqladmin  --socket=/tmp/node2.socket -u root shutdown  > /dev/null 2>&1

exit $EXTSTATUS
