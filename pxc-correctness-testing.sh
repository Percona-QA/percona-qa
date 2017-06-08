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
  wget https://www.percona.com/downloads/percona-toolkit/2.2.19/tarball/percona-toolkit-2.2.19.tar.gz
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
   $BASEDIR/bin/mysql --socket=/tmp/n1.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
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

#mysql install db check

if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
fi

archives() {
    tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
    rm -rf $WORKDIR
}

trap archives EXIT KILL

ps -ef | grep 'pxc-pxc-mysql.sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

SBENCH="sysbench"

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
  rm -Rf $node1 $node2 $node3
  mkdir -p $node1 $node2 $node3

   
  echo "Starting PXC node1"
  ${MID} --datadir=$node1  > ${WORKDIR}/logs/node1.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \
    --basedir=${BASEDIR} --datadir=$node1 --max-connections=2048 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $1 --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm:// \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
    --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${WORKDIR}/logs/node1.err \
    --socket=/tmp/n1.sock --log-output=none \
    --port=$RBASE1 --server-id=1 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node1.err 2>&1 &

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

  echo "Starting PXC node2"
  ${MID} --datadir=$node2  > ${WORKDIR}/logs/node2.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
    --basedir=${BASEDIR} --datadir=$node2 --max-connections=2048 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $1 --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR3 \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \
    --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${WORKDIR}/logs/node2.err \
    --socket=/tmp/n2.sock --log-output=none \
    --port=$RBASE2 --server-id=2 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node2.err 2>&1 &

  echo "Waiting for node-2 to start ....."
  MPID="$!"
  while true ; do
    sleep 10
    if egrep -qi  "Synchronized with group, ready for connections" ${WORKDIR}/logs/node2.err ; then
     break
    fi
    if [ "${MPID}" == "" ]; then
      echo "Error! server not started.. Terminating!"
      egrep -i "ERROR|ASSERTION" ${WORKDIR}/logs/node2.err
      exit 1
    fi
  done
  sleep 10

  echo "Starting PXC node3"
  ${MID} --datadir=$node3  > ${WORKDIR}/logs/node3.err 2>&1 || exit 1;

  ${BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.3 \
    --basedir=${BASEDIR} --datadir=$node3 --max-connections=2048 \
    --loose-debug-sync-timeout=600 --skip-performance-schema \
    --innodb_file_per_table $1 --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \
    --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2 \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR3 \
    --wsrep_sst_method=$sst_method --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --core-file --loose-new --sql-mode=no_engine_substitution \
    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${WORKDIR}/logs/node3.err \
    --socket=/tmp/n3.sock --log-output=none \
    --port=$RBASE3 --server-id=3 --wsrep_slave_threads=2 > ${WORKDIR}/logs/node3.err 2>&1 &

  # ensure that node-3 has started and has joined the group post SST
  echo "Waiting for node-3 to start ....."
  MPID="$!"
  while true ; do
    sleep 10
    if egrep -qi  "Synchronized with group, ready for connections" ${WORKDIR}/logs/node3.err ; then
     break
    fi
    if [ "${MPID}" == "" ]; then
      echo "Error! server not started.. Terminating!"
      egrep -i "ERROR|ASSERTION" ${WORKDIR}/logs/node3.err
      exit 1
    fi
  done

  if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/n1.sock ping > /dev/null 2>&1; then
   echo 'Started PXC node1...'
  else
   echo 'PXC node1 not stated...'
  fi
  if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/n2.sock ping > /dev/null 2>&1; then
   echo 'Started PXC node2...'
  else
   echo 'PXC node2 not stated...'
  fi
  if $BASEDIR/bin/mysqladmin -uroot --socket=/tmp/n3.sock ping > /dev/null 2>&1; then
   echo 'Started PXC node3...'
  else
   echo 'PXC node3 not stated...'
  fi
}

pxc_startup
check_script(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID}. Terminating!"; exit 1; fi
}

$BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -e "drop database if exists pxc_test;create database pxc_test;drop database if exists percona;create database percona;"
# Create DSNs table to run pt-table-checksum
$BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -e "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100), primary key(id));"
$BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -e "insert into percona.dsns (id,dsn) values (1,'h=127.0.0.1,P=$RBASE1,u=root');"
$BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -e "insert into percona.dsns (id,dsn) values (2,'h=127.0.0.1,P=$RBASE2,u=root');"
$BASEDIR/bin/mysql -uroot --socket=/tmp/n1.sock -e "insert into percona.dsns (id,dsn) values (3,'h=127.0.0.1,P=$RBASE3,u=root');"


#Sysbench prepare run
sysbench_run load_data pxc_test
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/n1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
check_script $? "Failed to run sysbench dataload"

if [[ ${PIPESTATUS[0]} -ne 0 ]];then
  echo "Sysbench run failed"
  EXTSTATUS=1
fi

echo "Loading sakila test database"
#$BASEDIR/bin/mysql --socket=/tmp/n1.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql
$BASEDIR/bin/mysql --socket=/tmp/n1.sock -u root < ${SCRIPT_PWD}/sample_db/sakila_workaround_bug81497.sql
check_script $? "Failed to load sakila test database"

echo "Loading world test database"
$BASEDIR/bin/mysql --socket=/tmp/n1.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql
check_script $? "Failed to load world test datbase"

echo "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql
check_script $? "Failed to load employees database with innodb engine"

echo "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql
check_script $? "Failed to load employees partitioned database with innodb engine"

for i in {1..5}; do
  # Sysbench transaction run
  sysbench_run oltp pxc_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/n1.sock run 2>&1 | tee $WORKDIR/logs/sysbench_rw_run.log
  check_script $? "Failed to run sysbench read write run"
  # Run pt-table-checksum to analyze data consistency
  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
    $BASEDIR/bin/mysql --socket=/tmp/n1.sock -u root -e "set global pxc_strict_mode=DISABLED" 
    pt-table-checksum h=127.0.0.1,P=$RBASE1,u=root -d pxc_test,world,employee_1,employee_2 --recursion-method dsn=h=127.0.0.1,P=$RBASE1,u=root,D=percona,t=dsns
    check_script $? "Failed to run pt-table-checksum"
    $BASEDIR/bin/mysql --socket=/tmp/n1.sock -u root -e "set global pxc_strict_mode=ENFORCING"
  else
    pt-table-checksum h=127.0.0.1,P=$RBASE1,u=root -d pxc_test,world,employee_1,employee_2 --recursion-method dsn=h=127.0.0.1,P=$RBASE1,u=root,D=percona,t=dsns
    check_script $? "Failed to run pt-table-checksum"
  fi
done

exit $EXTSTATUS

