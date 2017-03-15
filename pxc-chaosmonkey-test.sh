#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is for PXC ChaosMonkey Style testing
# Need to execute this script from PXC basedir

BUILD=$(pwd)
SKIP_RQG_AND_BUILD_EXTRACT=0
sst_method="rsync"
NODES=7
PXC_START_TIMEOUT=300

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SUSER=root
SPASS=
TSIZE=1000
TCOUNT=30
NUMT=30
SDURATION=1800

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
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql"
    fi
  fi
}

rm -rf ${BUILD}/pxc_chaosmonkey_testing.log &> /dev/null
echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${BUILD}" != "" ]; then echo "[$(date +'%T')] $1" >> ${BUILD}/pxc_chaosmonkey_testing.log; fi
}

if [ ! -r ${BUILD}/bin/mysqld ]; then  
  echoit "Please execute the script from PXC basedir"
  exit 1
fi

echoit "Starting $NODES node cluster for ChaosMonkey testing"
# Creating default my.cnf file
echo "[mysqld]" > my.cnf
echo "basedir=${BUILD}" >> my.cnf
echo "innodb_file_per_table" >> my.cnf
echo "innodb_autoinc_lock_mode=2" >> my.cnf
echo "innodb_locks_unsafe_for_binlog=1" >> my.cnf
echo "wsrep-provider=${BUILD}/lib/libgalera_smm.so" >> my.cnf
echo "wsrep_node_incoming_address=$ADDR" >> my.cnf
echo "wsrep_sst_method=rsync" >> my.cnf
echo "wsrep_sst_auth=$SUSER:$SPASS" >> my.cnf
echo "wsrep_node_address=$ADDR" >> my.cnf
echo "core-file" >> my.cnf
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
mkdir -p ${BUILD}/logs

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
      if  [ ! "$(ls -A $node)" ]; then 
        ${MID} --datadir=$node  > ${BUILD}/logs/startup_node$i.err 2>&1 || exit 1;
      fi
    fi
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > ${BUILD}/logs/startup_node$i.err 2>&1 || exit 1;
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
      --socket=$node/socket.sock --port=$RBASE1 > $node/node$i.err 2>&1 &
    MPID_ARRAY+=("$!")
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BUILD}/bin/mysqladmin -uroot -S$node/socket.sock ping > /dev/null 2>&1; then
        echoit "Started PXC node$i. Socket : $node/socket.sock"
        break
      fi
    done
  done
}

start_multi_node
# PXC cluster size info
echoit "Checking wsrep cluster size status.."
${BUILD}/bin/mysql -uroot --socket=${BUILD}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";

${BUILD}/bin/mysql  -uroot --socket=${BUILD}/node1/socket.sock -e"drop database if exists test;create database test"
#sysbench data load
echoit "Running sysbench load data..."
sysbench_run load_data test
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=${BUILD}/node1/socket.sock prepare > ${BUILD}/logs/sysbench_load.log 2>&1
#sysbench OLTP run
echoit "Initiated sysbench read write run ..."
sysbench_run oltp test
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=${BUILD}/node1/socket.sock run > ${BUILD}/logs/sysbench_rw_run.log 2>&1 &
SYSBENCH_PID="$!"

function recovery_test(){
  NUM="$(( ( RANDOM % $NODES )  + 1 ))"
  while [[ "$NUM" == "1" ]]
  do
    NUM="$(( ( RANDOM % $NODES )  + 1 ))"
  done  
  # Forcefully killing PXC node for recovery testing 
  kill -9 ${MPID_ARRAY[$NUM - 1]}
  wait ${MPID_ARRAY[$NUM - 1]} 2>/dev/null
  echoit "Forcefully killed PXC node$NUM for recovery testing "
  let PID=$NUM-1
  # With thanks, http://www.thegeekstuff.com/2010/06/bash-array-tutorial/
  MPID_ARRAY=(${MPID_ARRAY[@]:0:$PID} ${MPID_ARRAY[@]:$(($PID + 1))})
  sleep 30

  if [ $KEY_RING_CHECK -eq 1 ]; then
    KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${BUILD}/keyring_node$NUM/keyring"
  fi
  # Restarting forcefully killed PXC node.
  echoit "Restarting forcefully killed PXC node."
  RBASE1="$(( RBASE + ( 100 * $NUM ) ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  ${BUILD}/bin/mysqld --defaults-file=${BUILD}/my.cnf \
     --datadir=${BUILD}/node$NUM $WSREP_CLUSTER_ADD \
     --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
     --log-error=${BUILD}/node$NUM/node$NUM.err $KEY_RING_OPTIONS \
     --socket=${BUILD}/node$NUM/socket.sock --port=$RBASE1 > ${BUILD}/node$NUM/node$NUM.err 2>&1 &
  MPID_ARRAY+=("$!")

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
}

function multi_recovery_test(){
  # Picking random nodes from cluster 
  rand_nodes=(`shuf -i 1-6 -n 3 |  tr '\n' ' '`)
  kill -9 ${MPID_ARRAY[${rand_nodes[0]}]} ${MPID_ARRAY[${rand_nodes[1]}]} ${MPID_ARRAY[${rand_nodes[2]}]}
  wait ${MPID_ARRAY[${rand_nodes[0]}]} ${MPID_ARRAY[${rand_nodes[1]}]} ${MPID_ARRAY[${rand_nodes[2]}]} 2>/dev/null
  echoit "Forcefully killed PXC 3 nodes for recovery testing "
  sleep 30
  for j in `seq 0 2`;do
    let PID=${rand_nodes[$j]}+1
    # With thanks, http://www.thegeekstuff.com/2010/06/bash-array-tutorial/
    MPID_ARRAY=(${MPID_ARRAY[@]:0:$PID} ${MPID_ARRAY[@]:$(($PID + 1))})
  done
  for j in `seq 0 2`;do  
    let NUM=${rand_nodes[$j]}+1
    if [ $KEY_RING_CHECK -eq 1 ]; then
      KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${BUILD}/keyring_node$NUM/keyring"
    fi
    # Restarting forcefully killed PXC node.
    echoit "Restarting forcefully killed PXC node."
    RBASE1="$(( RBASE + ( 100 * $NUM ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    ${BUILD}/bin/mysqld --defaults-file=${BUILD}/my.cnf \
     --datadir=${BUILD}/node$NUM $WSREP_CLUSTER_ADD \
     --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
     --log-error=${BUILD}/node$NUM/node$NUM.err $KEY_RING_OPTIONS \
     --socket=${BUILD}/node$NUM/socket.sock --port=$RBASE1 > ${BUILD}/node$NUM/node$NUM.err 2>&1 &
    MPID_ARRAY+=("$!")

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
  done
}

function node_joining(){
  let i=$i+1
  RBASE1="$(( RBASE + ( 100 * $i ) ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
  node="${BUILD}/node$i"
  keyring_node="${BUILD}/keyring_node$i"

  if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
    mkdir -p $node $keyring_node
  fi
  if [ ! -d $node ]; then
    ${MID} --datadir=$node  > ${BUILD}/logs/startup_node$i.err 2>&1 || exit 1;
  fi
  if [ $KEY_RING_CHECK -eq 1 ]; then
    KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node/keyring"
  fi
  if [ $i -eq 1 ]; then
    WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
  else
    WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
  fi

  # Adding PXC node.
  echoit "Adding PXC node."
  ${BUILD}/bin/mysqld --defaults-file=${BUILD}/my.cnf \
     --datadir=${BUILD}/node$i $WSREP_CLUSTER_ADD \
     --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
     --log-error=$node/node$i.err $KEY_RING_OPTIONS \
     --socket=$node/socket.sock --port=$RBASE1 > $node/node$i.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BUILD}/bin/mysqladmin -uroot -S$node/socket.sock ping > /dev/null 2>&1; then
      echoit "Started PXC node$i. Socket : $node/socket.sock"
      break
    fi
  done

  # PXC cluster size info
  echoit "Checking wsrep cluster size status.."
  ${BUILD}/bin/mysql -uroot --socket=${BUILD}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";
}

function node_leaving(){
  NUM="$(( ( RANDOM % $NODES )  + 1 ))"
  while [[ "$NUM" == "1" ]]
  do
    NUM="$(( ( RANDOM % $NODES )  + 1 ))"
  done
  # Shutting down random PXC node 
  echoit "Shutting PXC node$NUM"
  ${BUILD}/bin/mysqladmin -uroot -S${BUILD}/node$NUM/socket.sock shutdown
  echoit "Server on socket ${BUILD}/node$NUM/socket.sock with datadir ${BUILD}/node$NUM halted"

  let NUM=$NUM-1
  MPID_ARRAY=(${MPID_ARRAY[@]:0:$NUM} ${MPID_ARRAY[@]:$(($NUM + 1))})

  # PXC cluster size info
  echoit "Checking wsrep cluster size status.."
  ${BUILD}/bin/mysql -uroot --socket=${BUILD}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";
}

echoit "** Starting multi node recovery test"
multi_recovery_test
echoit "** Starting single node joining test"
node_joining
echoit "** Starting single node recovery test"
recovery_test
echoit "** Starting single node leaving test"
node_leaving
node_leaving

kill -9 ${SYSBENCH_PID}
wait ${SYSBENCH_PID} 2>/dev/null

# Shutting down PXC nodes.
echoit "Shutting down PXC nodes"
let NODES=$NODES+1
for i in `seq 1 $NODES`;do
  ${BUILD}/bin/mysqladmin -uroot -S${BUILD}/node$i/socket.sock shutdown &> /dev/null
  echoit "Server on socket ${BUILD}/node$i/socket.sock with datadir ${BUILD}/node$i halted"
done

