#!/bin/bash
#######################################################################################
# Created by Ramesh Sivaraman, Percona LLC                                            #
# Updated by Mohit Joshi, Percona LLC                                                 #
# - Added support for PXC-8.0                                                         #
# - Improved the cleanup function                                                     #
# - Handled sysbench errors in version >=1.0 due to prepared statements (PS)          #
# Pre-requisites:                                                                     #
# - Ensure proxysql package is installed on the machine                               #
# - Ensure sysbench is installed on the machine                                       #
# Usage:                                                                              #
# - Create a work directory                                                           #
# - Download the latest PXC and PS tarball (tar.gz) pacakges inside work directory    #
#   URL: https://www.percona.com/downloads/Percona-XtraDB-Cluster-LATEST/#            #
# - Invoke the script:                                                                #
# eg ./pxc-proxysql-test.sh </path/to/workdir>                                        #
#######################################################################################

# User Configurable Variables
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

if [[ ! -e `which proxysql` ]];then
  echo "ProxySQL not found"
  exit 1
else
  PROXYSQL=`which proxysql`
fi

if [[ ! -e `which sysbench` ]];then
  echo "Sysbench not found"
  exit 1
else
  SBENCH=`which sysbench`
fi


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
ps -ef | grep 'node[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 > /dev/null 2>&1 || true

#Cleanup previous build directory
rm -rf $ROOT_FS/$BUILD_NUMBER
rm -rf $ROOT_FS/proxysql_datadir

cleanup(){
  tar czf results-${BUILD_NUMBER}.tar.gz -C $WORKDIR/logs . || true
  echo "Logs zipped successfully. Logs stored at: results-${BUILD_NUMBER}.tar.gz"
}

trap cleanup EXIT KILL
cd $ROOT_FS

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  SDURATION=30
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
  echo "Found PXC tarball package"
  tar -xzf $PXC_TAR
  echo "Extracted PXC tarball package successfully"
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* | grep -v ".tar" | head -n1`
else
  echo "Could not locate PXC tarball package in the $ROOT_FS. Exiting..."
  exit 1
fi

PS_TAR=`ls -1td ?ercona-?erver* | grep ".tar" | head -n1`

if [ ! -z $PS_TAR ];then
  echo "Found PS tarball package"
  tar -xzf $PS_TAR
  echo "Extracted PS tarball package successfully"
  PS_BASE=`ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1`
  PSBASE="$ROOT_FS/$PS_BASE"
else
  echo "Could not locate PS tarball package in the $ROOT_FS. Exiting..."
  exit 1
fi

if [[ ! -e `which proxysql` ]];then
  echo "ProxySQL not found"
  exit 1
else
  PROXYSQL=`which proxysql`
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
BASEDIR="${ROOT_FS}/$PXCBASE"
mkdir -p $WORKDIR  $WORKDIR/logs

# Setting seeddb creation configuration
if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '8\.[0]' | head -n1)" == "8.0" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[67]' | head -n1)" == "5.7" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[67]' | head -n1)" == "5.6" ]; then
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
fi

PORT_ARRAY=()
function pxc_startup(){
  for i in `seq 1 5`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    PORT_ARRAY+=("$RBASE1")
    WSREP_CLUSTER="${WSREP_CLUSTER}$LADDR1,"
    if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[67]' | head -n1)" == "5.6" ]; then
      WSREP_SST_AUTH="--wsrep_sst_auth=$USER:$PASS"
    elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[67]' | head -n1)" == "5.7" ]; then
      WSREP_SST_AUTH="--wsrep_sst_auth=$USER:$PASS"
    elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '8\.[0]' | head -n1)" == "8.0" ]; then
      WSREP_SST_AUTH=""
    fi
    node="${WORKDIR}/node$i"
    if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[67]' | head -n1)" == "5.6" ]; then
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
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm://$WSREP_CLUSTER"
    fi

    CMD="${BASEDIR}/bin/mysqld --no-defaults --basedir=${BASEDIR} \
 --wsrep-provider=${BASEDIR}/lib/libgalera_smm.so \
 --wsrep_node_incoming_address=$ADDR --wsrep_sst_method=xtrabackup-v2 $WSREP_SST_AUTH \
 --wsrep_node_address=$ADDR --datadir=$node \
 --innodb_autoinc_lock_mode=2 $WSREP_CLUSTER_ADD \
 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
 --wsrep_debug=1 \
 --pxc-encrypt-cluster-traffic=OFF \
 --log-error=$WORKDIR/logs/node$i.err  \
 --socket=/tmp/node${i}.sock --port=$RBASE1  --max-connections=2048"

    #echo "$CMD";
    $CMD > $node/node$i.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/node${i}.sock ping > /dev/null 2>&1; then
        echo "PXC Node$i started ok. Client: `echo "${BASEDIR}/bin/mysqld" | sed 's|/mysqld|/mysql|'` -uroot -S/tmp/node${i}.sock"
	break
      fi
    done
  done
  chmod 755 $WORKDIR/logs/*
}

proxysql_startup(){
  # Creating proxysql datadir
  echo "Creating ProxySQL data directory";
  mkdir -p $ROOT_FS/proxysql_datadir/
  # Copying the conf file into work directory
  echo "Writing the ProxySQL configuration file";
  cp $SCRIPT_PWD/proxysql.cnf $ROOT_FS/proxysql_datadir
  echo "Starting ProxySQL server...";
  echo "$PROXYSQL --initial -f -c $ROOT_FS/proxysql_datadir/proxysql.cnf > $ROOT_FS/proxysql_datadir/proxy.err"
  $PROXYSQL --initial -f -c $ROOT_FS/proxysql_datadir/proxysql.cnf > $ROOT_FS/proxysql_datadir/proxy.err 2>&1 &
  sleep 5

  echo "Creating ProxySQL users on PXC cluster node 1";

  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "CREATE USER 'proxysql'@'%' IDENTIFIED WITH mysql_native_password BY 'proxysql'"
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "CREATE USER 'monitor'@'%' IDENTIFIED BY 'monitor'"
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "GRANT ALL ON *.* TO 'proxysql'@'%'"
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "GRANT ALL ON *.* TO 'monitor'@'%'"
  ${BASEDIR}/bin/mysql -uroot  -S/tmp/node1.sock  -e "DROP DATABASE IF EXISTS sbtest;CREATE DATABASE sbtest;"

  echo "Inserting values into ProxySQL Database";
  ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -e "INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (0, '127.0.0.1', ${PORT_ARRAY[0]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[1]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[2]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[3]}, 20),(0, '127.0.0.1', ${PORT_ARRAY[4]}, 20)"

  echo "Adding proxysql user in PXC server"
  ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -e "INSERT INTO mysql_users (username, password, active, default_hostgroup, max_connections) VALUES ('proxysql', 'proxysql', 1, 0, 1024)"

  echo "Loading newly added MySQL users and Server to runtime"
  ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -e "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;LOAD MYSQL QUERY RULES TO RUNTIME;SAVE MYSQL QUERY RULES TO DISK;"
}

#PXC startup
echo "Starting PXC nodes..."
pxc_startup

#ProxySQL startup
proxysql_startup

echo "PXC and ProxySQL server started and configured successfully";

get_connection_pool(){
  echo -e "ProxySQL connection pool status\n"
  ${PSBASE}/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -t -e"SELECT srv_host,srv_port,status,Queries,Bytes_data_sent,Bytes_data_recv FROM stats_mysql_connection_pool;"
}

#Sysbench data load
sysbench_run load_data sbtest
echo -e "Preparing metadata for sysbench run...\n"
echo "$SBENCH $SYSBENCH_OPTIONS --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 prepare"
$SBENCH $SYSBENCH_OPTIONS --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

get_connection_pool

#Sysbench run
echo -e "Sysbench readonly run...\n"
for i in `seq 1 3`; do
  sysbench_run oltp_read sbtest
  echo "$SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 run"
  $SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 run 2>&1 | tee -a $WORKDIR/logs/sysbench_run.txt
  sleep 1
  get_connection_pool
done

echo -e "Sysbench read write run...\n"
for i in `seq 1 3`; do
  sysbench_run oltp sbtest
  echo "$SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 --mysql-ignore-errors=1317,1180,2013,1213,1062,1205 --db-ps-mode=disable run"
  $SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 --mysql-ignore-errors=1317,1180,2013,1213,1062,1205 --db-ps-mode=disable run 2>&1 | tee -a $WORKDIR/logs/sysbench_run.txt
  sleep 1
  get_connection_pool
done

echo -e "Shutting down node3 to check proxysql connection pooling status"
#Shutdown PXC node3
$BASEDIR/bin/mysqladmin --socket=/tmp/node3.sock -uroot shutdown

sleep 20
get_connection_pool

#Sysbench run
echo -e "Sysbench readonly run...\n"
for i in `seq 1 3`; do
  sysbench_run oltp_read sbtest
  echo "$SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 run"
  $SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 run 2>&1 | tee -a $WORKDIR/logs/sysbench_run.txt
  sleep 1
  get_connection_pool
done

echo -e "Sysbench read write run...\n"
for i in `seq 1 3`; do
  sysbench_run oltp sbtest
  echo "$SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 run --mysql-ignore-errors=1317,1180,2013,1213,1062,1205 --db-ps-mode=disable"
  $SBENCH $SYSBENCH_OPTIONS --forced-shutdown=5 --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1 --mysql-port=6033 --mysql-ignore-errors=1317,1180,2013,1213,1062,1205 --db-ps-mode=disable run 2>&1 | tee -a $WORKDIR/logs/sysbench_run.txt
  sleep 1
  get_connection_pool
done

echo -e "Shutting down remaining PXC nodes"
#Shutdown remaining PXC nodes
$BASEDIR/bin/mysqladmin  --socket=/tmp/node1.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node2.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node4.sock -u root shutdown
$BASEDIR/bin/mysqladmin  --socket=/tmp/node5.sock -u root shutdown

echo "Waiting for all nodes to shutdown completely..."
sleep 30
get_connection_pool
