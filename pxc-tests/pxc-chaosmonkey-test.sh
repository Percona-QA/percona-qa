#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is for PXC ChaosMonkey Style testing
# Need to execute this script from PXC basedir

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "./pxc-chaosmonkey-test.sh --workdir=PATH"
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

cd $ROOT_FS
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

rm -rf ${WORKDIR}/pxc_chaosmonkey_testing.log &> /dev/null
echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/pxc_chaosmonkey_testing.log; fi
}

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

# Setting xtrabackup SST method
if [[ $SST_METHOD == "xtrabackup-v2" ]];then
  PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
  if [ ! -z $PXB_BASE ];then
    export PATH="$ROOT_FS/$PXB_BASE/bin:$PATH"
  else
    if check_for_version $MYSQL_VERSION "8.0.0" ; then
      wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-8.0.4/binary/tarball/percona-xtrabackup-8.0.4-Linux-x86_64.libgcrypt20.tar.gz
    else
      wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-2.4.13/binary/tarball/percona-xtrabackup-2.4.13-Linux-x86_64.libgcrypt20.tar.gz
    fi
    tar -xzf percona-xtrabackup*.tar.gz
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$ROOT_FS/$PXB_BASE/bin:$PATH"
  fi
fi

declare MYSQL_VERSION=$(${PXCBASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

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

SKIP_RQG_AND_BUILD_EXTRACT=0
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

if [ ! -r ${PXCBASEDIR}/bin/mysqld ]; then
  echoit "Please execute the script from PXC basedir"
  exit 1
fi

echoit "Starting $NODES node cluster for ChaosMonkey testing"
# Creating default my.cnf file
echo "[mysqld]" > $WORKDIR/my.cnf
echo "basedir=${PXCBASEDIR}" >> $WORKDIR/my.cnf
echo "innodb_file_per_table" >> $WORKDIR/my.cnf
echo "innodb_autoinc_lock_mode=2" >> $WORKDIR/my.cnf
echo "wsrep-provider=${PXCBASEDIR}/lib/libgalera_smm.so" >> $WORKDIR/my.cnf
echo "wsrep_node_incoming_address=$ADDR" >> $WORKDIR/my.cnf
echo "wsrep_sst_method=$SST_METHOD" >> $WORKDIR/my.cnf
echo "wsrep_sst_auth=$SUSER:$SPASS" >> $WORKDIR/my.cnf
echo "wsrep_node_address=$ADDR" >> $WORKDIR/my.cnf
echo "core-file" >> $WORKDIR/my.cnf
echo "log-output=none" >> $WORKDIR/my.cnf
echo "server-id=1" >> $WORKDIR/my.cnf
echo "wsrep_slave_threads=2" >> $WORKDIR/my.cnf

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
    export PATH="$PXCBASEDIR/$PXB_BASE/bin:$PATH"
  else
    wget http://jenkins.percona.com/job/percona-xtrabackup-2.4-binary-tarball/label_exp=centos5-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unzip archive.zip
    tar -xzf archive/TARGET/*.tar.gz
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$PXCBASEDIR/$PXB_BASE/bin:$PATH"
  fi
fi

# Setting seeddb creation configuration
KEY_RING_CHECK=0
if check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${PXCBASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXCBASEDIR}"
  KEY_RING_CHECK=1
else
  MID="${PXCBASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXCBASEDIR}"
fi

MPID_ARRAY=()
function start_multi_node(){
  for i in `seq 1 $NODES`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
    node="${WORKDIR}/node$i"
    keyring_node="${WORKDIR}/keyring_node$i"

    if [ "$(${PXCBASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
      mkdir -p $node $keyring_node
      if  [ ! "$(ls -A $node)" ]; then
        ${MID} --datadir=$node  > ${WORKDIR}/logs/startup_node$i.err 2>&1 || exit 1;
      fi
    fi
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > ${WORKDIR}/logs/startup_node$i.err 2>&1 || exit 1;
    fi
    if [ $KEY_RING_CHECK -eq 1 ]; then
      KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node/keyring"
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
    fi

    ${PXCBASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/my.cnf \
      --datadir=$node $WSREP_CLUSTER_ADD \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$node/node$i.err $KEY_RING_OPTIONS \
      --socket=$node/socket.sock --port=$RBASE1 > $node/node$i.err 2>&1 &
    MPID_ARRAY+=("$!")
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXCBASEDIR}/bin/mysqladmin -uroot -S$node/socket.sock ping > /dev/null 2>&1; then
        echoit "Started PXC node$i. Socket : $node/socket.sock"
        break
      fi
    done
  done
}

start_multi_node
# PXC cluster size info
echoit "Checking wsrep cluster size status.."
${PXCBASEDIR}/bin/mysql -uroot --socket=${WORKDIR}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";

${PXCBASEDIR}/bin/mysql  -uroot --socket=${WORKDIR}/node1/socket.sock -e"drop database if exists test;create database test"
#sysbench data load
echoit "Running sysbench load data..."
sysbench_run load_data test
sysbench $SYSBENCH_OPTIONS --mysql-socket=${WORKDIR}/node1/socket.sock prepare > ${WORKDIR}/logs/sysbench_load.log 2>&1
#sysbench OLTP run
echoit "Initiated sysbench read write run ..."
sysbench_run oltp test
sysbench $SYSBENCH_OPTIONS --mysql-socket=${WORKDIR}/node1/socket.sock run > ${WORKDIR}/logs/sysbench_rw_run.log 2>&1 &
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
    KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${WORKDIR}/keyring_node$NUM/keyring"
  fi
  # Restarting forcefully killed PXC node.
  echoit "Restarting forcefully killed PXC node."
  RBASE1="$(( RBASE + ( 100 * $NUM ) ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  ${PXCBASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/my.cnf \
     --datadir=${WORKDIR}/node$NUM $WSREP_CLUSTER_ADD \
     --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
     --log-error=${WORKDIR}/node$NUM/node$NUM.err $KEY_RING_OPTIONS \
     --socket=${WORKDIR}/node$NUM/socket.sock --port=$RBASE1 > ${WORKDIR}/node$NUM/node$NUM.err 2>&1 &
  MPID_ARRAY+=("$!")

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${PXCBASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node$NUM/socket.sock ping > /dev/null 2>&1; then
      echoit "Started forcefully killed node"
      break
    fi
  done

  # PXC cluster size info
  echoit "Checking wsrep cluster size status.."
  ${PXCBASEDIR}/bin/mysql -uroot --socket=${WORKDIR}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";
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
      KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${WORKDIR}/keyring_node$NUM/keyring"
    fi
    # Restarting forcefully killed PXC node.
    echoit "Restarting forcefully killed PXC node."
    RBASE1="$(( RBASE + ( 100 * $NUM ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    ${PXCBASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/my.cnf \
     --datadir=${WORKDIR}/node$NUM $WSREP_CLUSTER_ADD \
     --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
     --log-error=${WORKDIR}/node$NUM/node$NUM.err $KEY_RING_OPTIONS \
     --socket=${WORKDIR}/node$NUM/socket.sock --port=$RBASE1 > ${WORKDIR}/node$NUM/node$NUM.err 2>&1 &
    MPID_ARRAY+=("$!")

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXCBASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node$NUM/socket.sock ping > /dev/null 2>&1; then
        echoit "Started forcefully killed node"
        break
      fi
    done

    # PXC cluster size info
    echoit "Checking wsrep cluster size status.."
    ${PXCBASEDIR}/bin/mysql -uroot --socket=${WORKDIR}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";
  done
}

function node_joining(){
  let i=$i+1
  RBASE1="$(( RBASE + ( 100 * $i ) ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
  node="${WORKDIR}/node$i"
  keyring_node="${WORKDIR}/keyring_node$i"

  if [ "$(${PXCBASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
    mkdir -p $node $keyring_node
  fi
  if [ ! -d $node ]; then
    ${MID} --datadir=$node  > ${WORKDIR}/logs/startup_node$i.err 2>&1 || exit 1;
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
  ${PXCBASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/my.cnf \
     --datadir=${WORKDIR}/node$i $WSREP_CLUSTER_ADD \
     --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
     --log-error=$node/node$i.err $KEY_RING_OPTIONS \
     --socket=$node/socket.sock --port=$RBASE1 > $node/node$i.err 2>&1 &

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${PXCBASEDIR}/bin/mysqladmin -uroot -S$node/socket.sock ping > /dev/null 2>&1; then
      echoit "Started PXC node$i. Socket : $node/socket.sock"
      break
    fi
  done

  # PXC cluster size info
  echoit "Checking wsrep cluster size status.."
  ${PXCBASEDIR}/bin/mysql -uroot --socket=${WORKDIR}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";
}

function node_leaving(){
  NUM="$(( ( RANDOM % $NODES )  + 1 ))"
  while [[ "$NUM" == "1" ]]
  do
    NUM="$(( ( RANDOM % $NODES )  + 1 ))"
  done
  # Shutting down random PXC node
  echoit "Shutting PXC node$NUM"
  ${PXCBASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node$NUM/socket.sock shutdown
  echoit "Server on socket ${WORKDIR}/node$NUM/socket.sock with datadir ${WORKDIR}/node$NUM halted"

  let NUM=$NUM-1
  MPID_ARRAY=(${MPID_ARRAY[@]:0:$NUM} ${MPID_ARRAY[@]:$(($NUM + 1))})

  # PXC cluster size info
  echoit "Checking wsrep cluster size status.."
  ${PXCBASEDIR}/bin/mysql -uroot --socket=${WORKDIR}/node1/socket.sock -e "show status like 'wsrep_cluster_size'";
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
  ${PXCBASEDIR}/bin/mysqladmin -uroot -S${WORKDIR}/node$i/socket.sock shutdown &> /dev/null
  echoit "Server on socket ${WORKDIR}/node$i/socket.sock with datadir ${WORKDIR}/node$i halted"
done

