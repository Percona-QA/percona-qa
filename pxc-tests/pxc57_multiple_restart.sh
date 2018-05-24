#!/bin/bash
# Created by Tomislav Plavcic, Percona LLC
# This script requires absolute path to test dir as parameter.
# In the testdir it needs 5.7 binary tarballs.
# It will install two 5.7 nodes and then repeatedly start/stop
# node2 until some test fails so it can be used for detecting sporadic
# start/stop issues.

if [ "$#" -ne 1 ]; then
  echo "This script requires absolute workdir as a parameter!";
  exit 1
fi

ulimit -c unlimited
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

# Parameter of parameterized build
if [ -z $SST_METHOD ]; then
  SST_METHOD="rsync"
fi
if [ -z $USE_PROXYSQL ]; then
  USE_PROXYSQL=0
fi

cd $WORKDIR

count=$(ls -1ct Percona-XtraDB-Cluster-5.7*.tar.gz | wc -l)
if [[ $count -gt 1 ]]; then
  for dirs in `ls -1ct Percona-XtraDB-Cluster-5.7*.tar.gz | tail -n +2`; do
     rm -rf $dirs
  done
fi
find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.7*' -exec rm -rf {} \+

echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster-5.7*.tar.gz | head -n1`
BASE2="$(tar tf $TAR | head -1 | tr -d '/')"
tar -xf $TAR

#
# Common functions
#
show_node_status(){
  local FUN_NODE_NR=$1
  local FUN_NODE_PATH=$2

  echo -e "\nShowing status of node${FUN_NODE_NR}:"
  grep -e "seqno.*-1" $FUN_NODE_PATH/grastate.dat
  if [ $? -eq 0 ]; then
    EXTSTATUS=1
  else
    EXTSTATUS=0
  fi
}

pxc_start_node(){
  local FUN_NODE_NR=$1
  local FUN_NODE_VER=$2
  local FUN_NODE_PATH=$3
  local FUN_CLUSTER_ADDRESS=$4
  local FUN_WSREP_PROVIDER_OPTIONS=$5
  local FUN_RBASE=$6
  local FUN_WSREP_PROVIDER=$7
  local FUN_LOG_ERR=$8
  local FUN_BASE_DIR=$9

  echo "Starting PXC-${FUN_NODE_VER} node${FUN_NODE_NR}"
  ${FUN_BASE_DIR}/bin/mysqld --no-defaults --defaults-group-suffix=.${FUN_NODE_NR} \
    --basedir=${FUN_BASE_DIR} --datadir=${FUN_NODE_PATH} \
    --innodb_file_per_table --innodb_autoinc_lock_mode=2 \
    --wsrep-provider=${FUN_WSREP_PROVIDER} \
    --wsrep_cluster_address=${FUN_CLUSTER_ADDRESS} \
    --wsrep_node_incoming_address=$ADDR \
    --wsrep_provider_options=${FUN_WSREP_PROVIDER_OPTIONS} \
    --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS \
    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \
    --query_cache_type=0 --query_cache_size=0 \
    --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
    --innodb_log_file_size=500M \
    --core-file --log_bin --binlog_format=ROW \
    --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${FUN_LOG_ERR} \
    --socket=/tmp/node${FUN_NODE_NR}.socket --log-output=none \
    --port=${FUN_RBASE} --server-id=${FUN_NODE_NR} --wsrep_slave_threads=8 > ${FUN_LOG_ERR} 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if $FUN_BASE_DIR/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
      break
    fi
  done
  if $FUN_BASE_DIR/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
    echo "PXC node${FUN_NODE_NR} started ok.."
  else
    echo "PXC node${FUN_NODE_NR} startup failed.. Please check error log: ${FUN_LOG_ERR}"
  fi

  sleep 10
}


# User settings
BUILD_NUMBER=1
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

MYSQL_BASEDIR2="${ROOT_FS}/$BASE2"
export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

echo "Workdir: $WORKDIR"
echo "Basedirs: $MYSQL_BASEDIR2"

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

#
# Install new cluster
#
echo -e "\n\n#### Installing new cluster\n"
${MYSQL_BASEDIR2}/bin/mysqld --initialize-insecure --basedir=${MYSQL_BASEDIR2} --datadir=$node1 > $WORKDIR/logs/node1-pre.err 2>&1 || exit 1;
pxc_start_node 1 "5.7" "$node1" "gcomm://" "gmcast.listen_addr=tcp://${LADDR1}" "$RBASE1" "${MYSQL_BASEDIR2}/lib/libgalera_smm.so" "$WORKDIR/logs/node1-pre.err" "${MYSQL_BASEDIR2}"

${MYSQL_BASEDIR2}/bin/mysqld --initialize-insecure --basedir=${MYSQL_BASEDIR2} --datadir=$node2 > $WORKDIR/logs/node2-pre.err 2>&1 || exit 1;

# repeatedly start/stop node2 until the test fails
TRIAL_NUM=0
while [ $EXTSTATUS -eq 0 ]; do
  TRIAL_NUM=$((TRIAL_NUM+1))
  pxc_start_node 2 "5.7" "$node2" "gcomm://$LADDR1" "gmcast.listen_addr=tcp://${LADDR2}" "$RBASE2" "${MYSQL_BASEDIR2}/lib/libgalera_smm.so" "$WORKDIR/logs/node2-pre.err" "${MYSQL_BASEDIR2}"

  sleep 10

  echo -e "\n\n*** TRIAL NUMBER: ${TRIAL_NUM} ***\n"

  ${MYSQL_BASEDIR2}/bin/mysql -S /tmp/node2.socket -u root -e "drop database if exists test2;"
  ${MYSQL_BASEDIR2}/bin/mysql -S /tmp/node2.socket -u root -e "create database test2;"
  ${MYSQL_BASEDIR2}/bin/mysql -S /tmp/node2.socket -u root -e "create table test2.aaa (a int primary key);"
  ${MYSQL_BASEDIR2}/bin/mysql -S /tmp/node2.socket -u root -e "insert into test2.aaa values (1);"

  echo "Shutting down node2 for test"
  ${MYSQL_BASEDIR2}/bin/mysqladmin --socket=/tmp/node2.socket -u root shutdown

  if [[ $? -ne 0 ]]; then
    echo "Shutdown failed for node2"
    exit 1
  fi

  sleep 10

  echo -e "\n\n#### Show grastate status after shutdown\n"
  show_node_status 2 "$node2"
done

#
# Check status after node2 shutdown
#
if [ $EXTSTATUS -ne 0 ]; then
  echo "Grastate on node2 incorrect! Please check log files."
else
  echo -e "All ok!\n\n"
fi

echo "Shutting down node1"
${MYSQL_BASEDIR2}/bin/mysqladmin --socket=/tmp/node1.socket -u root shutdown

if [[ $? -ne 0 ]]; then
  echo "Shutdown failed for node1"
  exit 1
fi
sleep 3

exit $EXTSTATUS
