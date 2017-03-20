#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
PXC_START_TIMEOUT=200
ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SUSER=root
SPASS=

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

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  SDURATION=50
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp_read" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp-read-only --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp_read" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_only.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql"
    fi
  fi
}

PXC_TAR=`ls -1td ?ercona-?tra??-?luster* | grep ".tar" | head -n1`

if [ ! -z $PXC_TAR ];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1`
  #Checking proxysql binary
  PROXYSQL_BIN=`ls -1t proxysql | head -n1`
  if [ ! -z $PROXYSQL_BIN ];then
    cp $PROXYSQL_BIN $PXCBASE/bin/
  fi
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
   $PSBASE/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

if [[ ! -e `which proxysql` ]];then 
  echo "proxysql not found" 
  exit 1
else
  PROXYSQL=`which proxysql`
fi

check_script(){
  MPID=$1
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID} empty. Terminating!"; exit 1; fi
}

GARBDBASE="$(( RBASE1 + 500 ))"
GARBDP="$ADDR:$GARBDBASE"

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
BASEDIR="${ROOT_FS}/$PXCBASE"
mkdir -p $WORKDIR  $WORKDIR/logs

# Setting seeddb creation configuration
if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
fi

PORT_ARRAY=()
function pxc_startup(){
  for i in `seq 1 5`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    PORT_ARRAY+=("$RBASE1")
    WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
    node="${WORKDIR}/node$i"
    if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
      mkdir -p $node
      ${MID} --datadir=$node  > $WORKDIR/logs/startup_node$i.err 2>&1
    else
      if [ ! -d $node ]; then
        ${MID} --datadir=$node  > $WORKDIR/logs/startup_node$i.err 2>&1
      fi
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
    fi

    ${BASEDIR}/bin/mysqld --no-defaults --basedir=${BASEDIR} \
      --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
      --wsrep_node_incoming_address=$ADDR --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \
      --wsrep_node_address=$ADDR --datadir=$node \
      --innodb_autoinc_lock_mode=2 $WSREP_CLUSTER_ADD $PXC_MYEXTRA \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$WORKDIR/logs/node$i.err  \
      --socket=/tmp/node${i}.sock --port=$RBASE1  --max-connections=2048 > $node/node$i.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node${i}.sock ping > /dev/null 2>&1; then
        echo "Started PXC node$i. Socket : /tmp/node${i}.sock"
        break
      fi
    done
  done
  chmod 755 $WORKDIR/logs/*
  ${BASEDIR}/bin/mysql -uroot -S/tmp/node1.sock -e "create database if not exists test" > /dev/null 2>&1
}

proxysql_startup(){
  $PROXYSQL --initial -f -c $SCRIPT_PWD/proxysql.cnf > /dev/null 2>&1 &
  check_script $?
  sleep 10
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "GRANT ALL ON *.* TO 'proxysql'@'%' IDENTIFIED BY 'proxysql'"
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "GRANT ALL ON *.* TO 'monitor'@'%' IDENTIFIED BY 'monitor'"
  check_script $?
  sleep 5
  echo  "INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (0, '127.0.0.1', ${PORT_ARRAY[0]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[1]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[2]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[3]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[4]}, 20)" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  check_script $?
  echo  "INSERT INTO mysql_users (username, password, active, default_hostgroup, max_connections) VALUES ('proxysql', 'proxysql', 1, 0, 1024)" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin 
  check_script $?
#  echo "INSERT INTO mysql_query_rules(active,match_pattern,destination_hostgroup,apply) VALUES(1,'^SELECT',0,1),(1,'^DELETE',0,1),(1,'^UPDATE',1,1),(1,'^INSERT',1,1)" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin
  echo "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;LOAD MYSQL QUERY RULES TO RUNTIME;SAVE MYSQL QUERY RULES TO DISK;" | ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin 
  check_script $?
  sleep 10
}

#PXC startup
pxc_startup
#ProxySQL startup
proxysql_startup
check_script $?

get_connection_pool(){
  echo -e "ProxySQL connection pool status\n"
  ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -t -e"select srv_host,srv_port,status,Queries,Bytes_data_sent,Bytes_data_recv from stats_mysql_connection_pool;"

}
#Sysbench data load
sysbench_run load_data test
$SBENCH $SYSBENCH_OPTIONS --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

check_script $?
get_connection_pool

echo "Loading sakila test database"
#$PSBASE/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${SCRIPT_PWD}/sample_db/sakila.sql
$PSBASE/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${SCRIPT_PWD}/sample_db/sakila_workaround_bug81497.sql
check_script $?
get_connection_pool

echo "Loading world test database"
$PSBASE/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${SCRIPT_PWD}/sample_db/world.sql
check_script $?
get_connection_pool

echo "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql
check_script $?
get_connection_pool

echo "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql
check_script $?
get_connection_pool


#Sysbench run
echo -e "Sysbench readonly run...\n"
for i in `seq 1 5`; do
  sysbench_run oltp_read test
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Sysbench read write run...\n"
for i in `seq 1 5`; do
  sysbench_run oltp test
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Shutting down node3 to check proxysql connection pooling status"
#Shutdown PXC node1
$BASEDIR/bin/mysqladmin  --socket=/tmp/node1.sock -u root shutdown

#Sysbench run
echo -e "Sysbench readonly run...\n"
for i in `seq 1 5`; do
  sysbench_run oltp_read test
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Sysbench read write run...\n"
for i in `seq 1 5`; do
  sysbench_run oltp test
  $SBENCH $SYSBENCH_OPTIONS--mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Shutting down remaining PXC nodes\n"
#Shutdown remaining PXC nodes
$BASEDIR/bin/mysqladmin  --socket=/tmp/node2.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node3.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node4.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node5.sock -u root shutdown

