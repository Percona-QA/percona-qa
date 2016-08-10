#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is for PXC ChaosMonkey Style testing

BUILD=$(pwd)
SKIP_RQG_AND_BUILD_EXTRACT=0
sst_method="rsync"
NODES=5
PXC_START_TIMEOUT=100

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SUSER=root
SPASS=

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${BUILD}" != "" ]; then echo "[$(date +'%T')] $1" >> ${BUILD}/pxc_chaosmonkey_testing.log; fi
}

echoit "Starting $NODES node cluster for ChaosMonkey testiing"
# Creating default my.cnf file
echo "[mysqld]" > my.cnf
echo "basedir=${BUILD}" >> my.cnf
echo "loose-debug-sync-timeout=600" >> my.cnf
echo "innodb_file_per_table" >> my.cnf
echo "innodb_autoinc_lock_mode=2" >> my.cnf
echo "innodb_locks_unsafe_for_binlog=1" >> my.cnf
echo "wsrep-provider=${BUILD}/lib/libgalera_smm.so" >> my.cnf
echo "wsrep_node_incoming_address=$ADDR" >> my.cnf
echo "wsrep_sst_method=rsync" >> my.cnf
echo "wsrep_sst_auth=$SUSER:$SPASS" >> my.cnf
echo "wsrep_node_address=$ADDR" >> my.cnf 
echo "innodb_flush_method=O_DIRECT" >> my.cnf
echo "core-file" >> my.cnf
echo "sql-mode=no_engine_substitution" >> my.cnf
echo "loose-innodb-status-file=1" >> my.cnf
echo "log-output=none" >> my.cnf
echo "server-id=1" >> my.cnf
echo "wsrep_slave_threads=2" >> my.cnf

# Ubuntu mysqld runtime provisioning
if [ "$(uname -v | grep 'Ubuntu')" != "" ]; then
  if [ "$(dpkg -l | grep 'libaio1')" == "" ]; then
    sudo apt-get install libaio1 
  fi
  if [ "$(dpkg -l | grep 'libjemalloc1')" == "" ]; then
    sudo apt-get install libjemalloc1
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libssl.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libssl.so.1.0.0 /lib/x86_64-linux-gnu/libssl.so.6
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libcrypto.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libcrypto.so.1.0.0 /lib/x86_64-linux-gnu/libcrypto.so.6
  fi
fi

# Setting xtrabackup SST method
if [[ $sst_method == "xtrabackup" ]];then
  PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
  if [ ! -z $PXB_BASE ];then
    export PATH="$BUILD/$PXB_BASE/bin:$PATH"
  else
    wget http://jenkins.percona.com/job/percona-xtrabackup-2.4-binary-tarball/label_exp=centos5-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unzip archive.zip
    tar -xzf archive/TARGET/*.tar.gz 
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$BUILD/$PXB_BASE/bin:$PATH"
  fi
fi

# Setting seeddb creation configuration
KEY_RING_CHECK=0
if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BUILD}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BUILD}"
  KEY_RING_CHECK=1
elif [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BUILD}/scripts/mysql_install_db --no-defaults --basedir=${BUILD}"
fi

# Creating logs dir to save sysbench run log.
mkdir ${BUILD}/logs

MPID_ARRAY=()
function start_multi_node(){
  for i in `seq 1 $NODES`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
    node="${BUILD}/node$i"
    keyring_node="${BUILD}/keyring_node$i"

    if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
      mkdir -p $node $keyring_node
    fi
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > ${BUILD}/startup_node$i.err 2>&1 || exit 1;
    fi
    if [ $KEY_RING_CHECK -eq 1 ]; then
      KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node/keyring"
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
    fi

    ${BUILD}/bin/mysqld --defaults-file=${BUILD}/my.cnf \
      --datadir=$node $WSREP_CLUSTER_ADD \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$node/node$i.err $KEY_RING_OPTIONS \
      --socket=$node/socket.sock --port=$RBASE1 2>&1 &
    MPID_ARRAY+=("$!")
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BUILD}/bin/mysqladmin -uroot -S$node/socket.sock ping > /dev/null 2>&1; then
        echoit "Started PXC node$i. Socket : {BUILD}/node$i/socket.sock"
        break
      fi
    done
  done
}

start_multi_node

${BUILD}/bin/mysql  -uroot --socket=${BUILD}/node1/socket.sock -e"create database if not exists test"
#sysbench data load
echoit "Running sysbench load data..."
sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --num-threads=30 --oltp_tables_count=30 --oltp_table_size=1000 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock run > ${BUILD}/logs/sysbench_load.log 2>&1
#sysbench OLTP run
echoit "Initiated sysbench read write run ..."
sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua --report-interval=1 --num-threads=30 --max-time=600 --max-requests=1870000000 --oltp-tables-count=30 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock run > ${BUILD}/logs/sysbench_rw_run.log 2>&1 &

NUM="$(( ( RANDOM % $NODES )  + 1 ))"
if [ $NUM -eq 1 ]; then
  WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
fi

# Forcefully killing PXC node for recovery testing 
echoit "Forcefully killing PXC node for recovery testing "
kill -9 ${MPID_ARRAY[$NUM - 1]}
sleep 30

# Restarting forcefully killed PXC node.
echoit "Restarting forcefully killed PXC node."
RBASE1="$(( RBASE + ( 100 * $NUM ) ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"
${BUILD}/bin/mysqld --defaults-file=${BUILD}/my.cnf \
   --datadir=${BUILD}/node$NUM $WSREP_CLUSTER_ADD \
   --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
   --log-error=${BUILD}/node$NUM/node$NUM.err --early-plugin-load=keyring_file.so \
   --keyring_file_data=${BUILD}/keyring_node$NUM/keyring \
   --socket=${BUILD}/node$NUM/socket.sock --port=$RBASE1 2>&1 &

for X in $(seq 0 ${PXC_START_TIMEOUT}); do
  sleep 1
  if ${BUILD}/bin/mysqladmin -uroot -S${BUILD}/node$NUM/socket.sock ping > /dev/null 2>&1; then
    echoit "Started forcefully killed node"
    break
  fi
done

# PXC cluster size info
echoit "Checking wsrep cluster size status.."
${BUILD}/bin/mysql -uroot --socket=${BUILD}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";

# Shutting down PXC nodes.
echoit "Shutting down PXC nodes"
for i in `seq 1 $NODES`;do
  ${BUILD}/bin/mysqladmin -uroot -S${BUILD}/node$i/socket.sock shutdown
  echoit "Server on socket {BUILD}/node$i/socket.sock with datadir {BUILD}/node$i halted"
done

