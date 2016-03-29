#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

if [ -z $1 ]; then
  echo "No valid parameters were passed. Need relative workdir setting. Retry.";
  echo "Usage example:"
  echo "$./pxc-correctness-testing.sh /sda/pxc-correctness-testing"
  exit 1
else
  WORKDIR=$1
fi

ROOT_FS=$WORKDIR
sst_method="rsync"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
echo "${SCRIPT_PWD}.."

cd $WORKDIR
count=$(ls -1ct Percona-XtraDB-Cluster-5.*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then
  for dirs in `ls -1ct Percona-XtraDB-Cluster-5.*.tar.gz | tail -n +2`;do
     rm -rf $dirs
  done
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.*' -exec rm -rf {} \+

echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster-5.*.tar.gz | head -n1`
BASEDIR="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR

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

# Parameter of parameterized build
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi
if [ -z ${SDURATION} ]; then
  SDURATION=100
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

EXTSTATUS=0

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
   $BASEDIR/bin/mysql --socket=${node1}/pxc-mysql.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

if [ ! -d ${ROOT_FS}/$BASEDIR ]; then
  echo "Base directory does not exist. Fatal error.";
  exit 1
else
  BASEDIR="${ROOT_FS}/$BASEDIR"
fi

trap "tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs" EXIT KILL

ps -ef | grep 'pxc-pxc-mysql.sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

SYSBENCH_LOC="/usr/share/doc/sysbench/tests/db"
SBENCH="sysbench"

# Installing percona tookit
if ! rpm -qa | grep -qw percona-toolkit ; then 
  sudo yum install percona-toolkit
fi

pxc_startup(){
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
  
  SUSER=root
  SPASS=
  
  node1="${WORKDIR}/node1"
  node2="${WORKDIR}/node2"
  node3="${WORKDIR}/node3"
  mkdir -p $node1 $node2 $node3

   
  echo 'Starting PXC nodes....'
  pushd ${BASEDIR}/mysql-test/
  
  set +e 
   perl mysql-test-run.pl \
      --start-and-exit \
      --port-base=$RBASE1 \
      --nowarnings \
      --vardir=$node1 \
      --mysqld=--skip-performance-schema  \
      --mysqld=--innodb_file_per_table \
      --mysqld=--binlog-format=ROW \
      --mysqld=--wsrep-slave-threads=2 \
      --mysqld=--innodb_autoinc_lock_mode=2 \
      --mysqld=--innodb_locks_unsafe_for_binlog=1 \
      --mysqld=--wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
      --mysqld=--wsrep_cluster_address=gcomm:// \
      --mysqld=--wsrep_sst_receive_address=$RADDR1 \
      --mysqld=--wsrep_node_incoming_address=$ADDR \
      --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1" \
      --mysqld=--wsrep_sst_method=$sst_method \
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
      --mysqld=--socket=$node1/pxc-mysql.sock \
      --mysqld=--log-error=$node1/node1.err \
      --mysqld=--log-output=none \
     1st > $node1/node1.err 2>&1 
  set -e
  set +e 
   perl mysql-test-run.pl \
      --start-and-exit \
      --port-base=$RBASE2 \
      --nowarnings \
      --vardir=$node2 \
      --mysqld=--skip-performance-schema  \
      --mysqld=--innodb_file_per_table  \
      --mysqld=--binlog-format=ROW \
      --mysqld=--wsrep-slave-threads=2 \
      --mysqld=--innodb_autoinc_lock_mode=2 \
      --mysqld=--innodb_locks_unsafe_for_binlog=1 \
      --mysqld=--wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
      --mysqld=--wsrep_cluster_address=gcomm://$LADDR1 \
      --mysqld=--wsrep_sst_receive_address=$RADDR2 \
      --mysqld=--wsrep_node_incoming_address=$ADDR \
      --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2" \
      --mysqld=--wsrep_sst_method=$sst_method \
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
      --mysqld=--socket=$node2/pxc-mysql.sock \
      --mysqld=--log-error=$node2/node2.err \
      --mysqld=--log-output=none \
     1st > $node2/node2.err 2>&1
  set -e
  set +e 
   perl mysql-test-run.pl \
      --start-and-exit \
      --port-base=$RBASE3 \
      --nowarnings \
      --vardir=$node3 \
      --mysqld=--skip-performance-schema  \
      --mysqld=--innodb_file_per_table  \
      --mysqld=--binlog-format=ROW \
      --mysqld=--wsrep-slave-threads=2 \
      --mysqld=--innodb_autoinc_lock_mode=2 \
      --mysqld=--innodb_locks_unsafe_for_binlog=1 \
      --mysqld=--wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
      --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
      --mysqld=--wsrep_sst_receive_address=$RADDR3 \
      --mysqld=--wsrep_node_incoming_address=$ADDR \
      --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR3" \
      --mysqld=--wsrep_sst_method=$sst_method \
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
      --mysqld=--socket=$node3/pxc-mysql.sock \
      --mysqld=--log-error=$node3/node3.err \
      --mysqld=--log-output=none \
     1st > $node3/node3.err 2>&1
   set -e
  popd
  if $BASEDIR/bin/mysqladmin -uroot --socket=${node1}/pxc-mysql.sock ping > /dev/null 2>&1; then
   echo 'Started PXC node1...'
  else
   echo 'PXC node1 not stated...'
  fi
  if $BASEDIR/bin/mysqladmin -uroot --socket=${node2}/pxc-mysql.sock ping > /dev/null 2>&1; then
   echo 'Started PXC node2...'
  else
   echo 'PXC node2 not stated...'
  fi
  if $BASEDIR/bin/mysqladmin -uroot --socket=${node3}/pxc-mysql.sock ping > /dev/null 2>&1; then
   echo 'Started PXC node3...'
  else
   echo 'PXC node3 not stated...'
  fi
}

pxc_startup

$BASEDIR/bin/mysql -uroot --socket=$node1/pxc-mysql.sock -e "drop database if exists pxc_test;create database pxc_test;drop database if exists percona;create database percona;"
# Create DSNs table to run pt-table-checksum
$BASEDIR/bin/mysql -uroot --socket=$node1/pxc-mysql.sock -e "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100));"
$BASEDIR/bin/mysql -uroot --socket=$node1/pxc-mysql.sock -e "insert into percona.dsns (id,dsn) values (1,'h=127.0.0.1,P=$RBASE1,u=root');"
$BASEDIR/bin/mysql -uroot --socket=$node1/pxc-mysql.sock -e "insert into percona.dsns (id,dsn) values (2,'h=127.0.0.1,P=$RBASE2,u=root');"
$BASEDIR/bin/mysql -uroot --socket=$node1/pxc-mysql.sock -e "insert into percona.dsns (id,dsn) values (3,'h=127.0.0.1,P=$RBASE3,u=root');"


#Sysbench prepare run
$SBENCH --test=$SYSBENCH_LOC/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=${node1}/pxc-mysql.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

if [[ ${PIPESTATUS[0]} -ne 0 ]];then
  echo "Sysbench run failed"
  EXTSTATUS=1
fi

echo "Loading sakila test database"
$BASEDIR/bin/mysql --socket=$node1/pxc-mysql.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echo "Loading world test database"
$BASEDIR/bin/mysql --socket=$node1/pxc-mysql.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echo "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql

echo "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql

for i in {1..5}; do
  # Sysbench transaction run
  $SBENCH --test=$SYSBENCH_LOC/oltp.lua --mysql-socket=${node1}/pxc-mysql.sock  --mysql-user=root --num-threads=$NUMT --oltp-tables-count=$TCOUNT --mysql-db=test --oltp-table-size=$TSIZE --max-time=$SDURATION --report-interval=1 --max-requests=0 --tx-rate=100 run | grep tps > /dev/null 2>&1
  # Run pt-table-checksum to analyze data consistency 
  pt-table-checksum h=127.0.0.1,P=$RBASE1,u=root -d test --recursion-method dsn=h=127.0.0.1,P=$RBASE1,u=root,D=percona,t=dsns
done

exit $EXTSTATUS
