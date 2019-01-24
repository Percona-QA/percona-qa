#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# pxc proxysql testing with network namespace

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "./pxc-nw-ns-proxysql_test.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                     Specify work directory"
  echo "  -b, --build-number=NUMBER              Specify work build directory"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:s:h --longoptions=workdir:,build-number:,sst-method:,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- "$go_out"
fi

if [[ $go_out == " --" ]];then
  usage
  exit 1
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -w | --workdir )
    export WORKDIR="$2"
    if [[ ! -d "$WORKDIR" ]]; then
      echo "ERROR: Workdir ($WORKDIR) directory does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -b | --build-number )
    export BUILD_NUMBER="$2"
    shift 2
    ;;
    -s | --sst-method )
    export SST_METHOD="$2"
    shift 2
    if [[ "$SST_METHOD" != "rsync" ]] && [[ "$SST_METHOD" != "xtrabackup-v2" ]] ; then
      echo "ERROR: Invalid --sst-method passed:"
      echo "  Please choose any of these sst-method options: 'rsync' or 'xtrabackup-v2'"
      exit 1
    fi
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

#Format version string (thanks to wsrep_sst_xtrabackup-v2) 
normalize_version(){
  local major=0
  local minor=0
  local patch=0
  
  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  fi
  printf %02d%02d%02d $major $minor $patch
}

#Version comparison script (thanks to wsrep_sst_xtrabackup-v2) 
check_for_version()
{
  local local_version_str="$( normalize_version $1 )"
  local required_version_str="$( normalize_version $2 )"
  
  if [[ "$local_version_str" < "$required_version_str" ]]; then
    return 1
  else
    return 0
  fi
}

# generic variables
if [[ -z "$WORKDIR" ]]; then
  export WORKDIR=${PWD}
fi
ROOT_FS=$WORKDIR
if [[ -z "$SST_METHOD" ]]; then
  export SST_METHOD="xtrabackup-v2"
fi
if [[ -z ${BUILD_NUMBER} ]]; then
  BUILD_NUMBER=1001
fi

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
SCRIPT_PWD=$(cd `dirname $0` && pwd)
LPATH="/usr/share/doc/sysbench/tests/db"
PXC_START_TIMEOUT=200
cd $ROOT_FS
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

# Check sudo privilleges for creating network namespace
if ! sudo -l | grep ALL ; then
  if ! sudo -l | grep ip ; then
    echo "$(whoami) does not have sudo privillege"
    exit 1
  fi
fi

# Create network namespace for proxysql testing
create_nw_ns(){
  BRIDGE=br-pxc
  sudo brctl addbr $BRIDGE
  sudo brctl stp $BRIDGE off
  sudo ip addr add 10.200.10.1/24 dev $BRIDGE
  sudo ip link set dev $BRIDGE up

  # Create namespace
  for i in 1 2 3 4
  do
    sudo ip netns add pxc_ns$i
    sudo ip link add pxc-veth$i type veth peer name br-pxc-veth$i
    sudo brctl addif $BRIDGE br-pxc-veth$i
    sudo ip link set pxc-veth$i netns pxc_ns$i
    sudo ip netns exec pxc_ns$i ip addr add 10.200.10.$((i+1))/24 dev pxc-veth$i
    sudo ip netns exec pxc_ns$i ip link set dev pxc-veth$i up
    sudo ip link set dev br-pxc-veth$i up
    sudo ip netns exec pxc_ns$i ip link set lo up
    sudo ip netns exec pxc_ns$i ip route add default via 10.200.10.1
  done

  # enable communication between nodes
  sudo iptables -t nat -A POSTROUTING -s 10.200.10.0/255.255.255.0 -o enp2s0f0 -j MASQUERADE
  sudo iptables -A FORWARD -i enp2s0f0 -o $BRIDGE -j ACCEPT
  sudo iptables -A FORWARD -o enp2s0f0 -i $BRIDGE -j ACCEPT
}

# Delete network namespace
destroy_nw_ns(){
  BRIDGE=br-pxc
  # delete namespace
  for i in 1 2 3 4
  do
    sudo ip link set dev br-pxc-veth$i down
    sudo ip netns delete pxc_ns$i
  done
  sudo ip link set dev $BRIDGE down
  sudo brctl delbr $BRIDGE

}

# For local run - User Configurable Variables
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
destroy_nw_ns
#Kill existing mysqld process
ps -ef | grep 'n[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 > /dev/null 2>&1 || true

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL
cd $ROOT_FS

#Check PXC binary tar ball
PXC_TAR=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep ".tar" | head -n1`
if [[ ! -z $PXC_TAR ]];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
else
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  if [[ -z $PXCBASE ]] ; then
    echoit "ERROR! Could not find PXC base directory."
    exit 1
  else
    export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
  fi
fi
PXCBASEDIR="${ROOT_FS}/$PXCBASE"
declare MYSQL_VERSION=$(${PXC_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

#Checking proxysql binary
PROXYSQL_BIN=`ls -1t proxysql | head -n1`
if [ ! -z $PROXYSQL_BIN ];then
  cp $PROXYSQL_BIN $PXCBASE/bin/
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
   $PXCBASEDIR/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
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
mkdir -p $WORKDIR  $WORKDIR/logs

pxc_startup(){
  if check_for_version $MYSQL_VERSION "5.7.0" ; then
    MID="${PXCBASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXCBASEDIR}"
  else
    MID="$PXCBASEDIR/scripts/mysql_install_db --no-defaults --basedir=$PXCBASEDIR"
  fi

  node1="${WORKDIR}/node1"
  node2="${WORKDIR}/node2"
  node3="${WORKDIR}/node3"
  node4="${WORKDIR}/node4"

  if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
    mkdir -p $node1
  fi
  ${MID} --datadir=$node1  > ${WORKDIR}/startup_node1.err 2>&1 || exit 1;

  sudo ip netns exec pxc_ns1 $PXCBASEDIR/bin/mysqld --defaults-file=${SCRIPT_PWD}/pxc_node.cnf --basedir=$PXCBASEDIR --datadir=$node1 --wsrep-provider=$PXCBASEDIR/lib/libgalera_smm.so --log-error=${WORKDIR}/logs/node1.err --socket=/tmp/node1.sock  --user=ramesh --wsrep_cluster_name=cluster1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if $PXCBASEDIR/bin/mysqladmin -uroot -S/tmp/node1.sock ping > /dev/null 2>&1; then
      break
    fi
  done

  ${MID} --datadir=$node2  > ${WORKDIR}/startup_node2.err 2>&1 || exit 1;

  sudo ip netns exec pxc_ns2 $PXCBASEDIR/bin/mysqld --defaults-file=${SCRIPT_PWD}/pxc_node.cnf --basedir=$PXCBASEDIR --datadir=$node2 --wsrep-provider=$PXCBASEDIR/lib/libgalera_smm.so --log-error=${WORKDIR}/logs/node2.err --socket=/tmp/node2.sock --user=ramesh --wsrep_cluster_address="gcomm://10.200.10.3"  --wsrep_cluster_name=cluster1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if $PXCBASEDIR/bin/mysqladmin -uroot -S/tmp/node2.sock ping > /dev/null 2>&1; then
      break
    fi
  done

  ${MID} --datadir=$node3  > ${WORKDIR}/startup_node3.err 2>&1 || exit 1;

  sudo ip netns exec pxc_ns3 $PXCBASEDIR/bin/mysqld --defaults-file=${SCRIPT_PWD}/pxc_node.cnf --basedir=$PXCBASEDIR --datadir=$node3 --wsrep-provider=$PXCBASEDIR/lib/libgalera_smm.so --log-error=${WORKDIR}/logs/node3.err --socket=/tmp/node3.sock --user=ramesh --wsrep_cluster_address="gcomm://10.200.10.4"  --wsrep_cluster_name=cluster1 &


  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if $PXCBASEDIR/bin/mysqladmin -uroot -S/tmp/node3.sock ping > /dev/null 2>&1; then
      $PXCBASEDIR/bin/mysql -uroot -S/tmp/node1.sock -e "create database if not exists test" > /dev/null 2>&1
      sleep 2
      break
    fi
  done
}

create_nw_ns
pxc_startup

proxysql_startup(){
  $PROXYSQL --initial -f -c $SCRIPT_PWD/proxysql.cnf > /dev/null 2>&1 &
  check_script $?
  sleep 10
  sudo ip netns exec pxc_ns1 $PXCBASEDIR/bin/mysql -uroot  -S/tmp/node1.sock  -e "GRANT ALL ON *.* TO 'proxysql'@'%' IDENTIFIED BY 'proxysql'"
  check_script $?
  $PXCBASEDIR/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -e "INSERT INTO mysql_servers (hostgroup_id, hostname, port, max_replication_lag) VALUES (0, '10.200.10.2', 3306, 20),(0, '10.200.10.3', 3306, 20),(0, '10.200.10.4', 3306, 20)"
  check_script $?
  $PXCBASEDIR/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -e "INSERT INTO mysql_users (username, password, active, default_hostgroup, max_connections) VALUES ('proxysql', 'proxysql', 1, 0, 1024)"
  check_script $?
  $PXCBASEDIR/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -e "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;"
  check_script $?
  sleep 10
}

#ProxySQL startup
proxysql_startup
check_script $?

get_connection_pool(){
  echo -e "ProxySQL connection pool status\n"
  $PXCBASEDIR/bin/mysql -h 127.0.0.1 -P6032 -uadmin -padmin -t -e "select srv_host,srv_port,status,Queries,Bytes_data_sent,Bytes_data_recv from stats_mysql_connection_pool;"

}
#Sysbench data load
$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE \
  --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1  --num-threads=$TCOUNT --db-driver=mysql \
  prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

check_script $?
get_connection_pool

echo "Loading sakila test database"
#$PXCBASEDIR/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${SCRIPT_PWD}/sample_db/sakila.sql
$PXCBASEDIR/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${SCRIPT_PWD}/sample_db/sakila_workaround_bug81497.sql
check_script $?
get_connection_pool

echo "Loading world test database"
$PXCBASEDIR/bin/mysql --user=proxysql --password=proxysql --host=127.0.0.1 < ${SCRIPT_PWD}/sample_db/world.sql
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
  $SBENCH --report-interval=10 --oltp-auto-inc=off --max-time=50 --max-requests=1870000000 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp_tables_count=$TCOUNT --num-threads=$NUMT --oltp_table_size=$TSIZE --oltp-read-only --mysql-db=test --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1  --db-driver=mysql run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Sysbench read write run...\n"
for i in `seq 1 5`; do
  $SBENCH --report-interval=10 --oltp-auto-inc=off --max-time=50 --max-requests=1870000000 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --num-threads=$NUMT --oltp_table_size=$TSIZE --mysql-db=test --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1  --db-driver=mysql run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Shutting down node3 to check proxysql connection pooling status"
#Shutdown PXC node1
$PXCBASEDIR/bin/mysqladmin  --socket=/tmp/node1.sock -u root shutdown

#Sysbench run
echo -e "Sysbench readonly run...\n"
for i in `seq 1 5`; do
  $SBENCH --report-interval=10 --oltp-auto-inc=off --max-time=50 --max-requests=1870000000 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp_tables_count=$TCOUNT --num-threads=$NUMT --oltp_table_size=$TSIZE --oltp-read-only --mysql-db=test --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1  --db-driver=mysql run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Sysbench read write run...\n"
for i in `seq 1 5`; do
  $SBENCH --report-interval=10 --oltp-auto-inc=off --max-time=50 --max-requests=1870000000 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --num-threads=$NUMT --oltp_table_size=$TSIZE --mysql-db=test --mysql-user=proxysql --mysql-password=proxysql --mysql-host=127.0.0.1  --db-driver=mysql run 2>&1 | tee $WORKDIR/logs/sysbench_run.txt
  check_script $?
  sleep 1
  get_connection_pool
done

echo -e "Shutting down remaining PXC nodes\n"
#Shutdown remaining PXC nodes
$PXCBASEDIR/bin/mysqladmin  --socket=/tmp/node2.sock -u root shutdown
$PXCBASEDIR/bin/mysqladmin  --socket=/tmp/node3.sock -u root shutdown

destroy_nw_ns

