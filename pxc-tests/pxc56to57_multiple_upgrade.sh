#!/bin/bash
# Created by Tomislav Plavcic, Percona LLC
# This script requires absolute path to test dir as parameter.
# In the testdir it needs 5.6 and 5.7 binary tarballs.
# It will install two 5.6 nodes and then upgrade second node to 5.7
# and then make some check on the upgraded node.
# If the test is successful it will stop mysqld's and re-run from beginning.
# If the check fails it will leave the mysqld's running and stop executing.

if [ "$#" -ne 1 ]; then
  echo "This script requires absolute workdir as a parameter!";
  exit 1
fi

NUMBEROFTRIALS=30

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

count=$(ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | wc -l)
if [[ $count -gt 1 ]]; then
  for dirs in `ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | tail -n +2`; do
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

#
# Common functions
#
show_node_status(){
  local FUN_NODE_NR=$1
  local FUN_MYSQL_BASEDIR=$2
  local SHOW_SYSBENCH_COUNT=$3

  echo -e "\nShowing status of node${FUN_NODE_NR}:"
  ${FUN_MYSQL_BASEDIR}/bin/mysql -S /tmp/node${FUN_NODE_NR}.socket -u root -e "show global variables like 'version';" > $WORKDIR/logs/node${FUN_NODE_NR}_version_check.txt 2>&1
  EXTSTATUS=$?
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
    --loose-debug-sync-timeout=600 \
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

pxc_upgrade_node(){
  local FUN_NODE_NR=$1
  local FUN_NODE_VER=$2
  local FUN_NODE_PATH=$3
  local FUN_RBASE=$4
  local FUN_LOG_ERR=$5
  local FUN_BASE_DIR=$6

  echo -e "\n\n#### Upgrade node${FUN_NODE_NR} to the version ${FUN_NODE_VER}\n"
  echo "Shutting down node${FUN_NODE_NR} for upgrade"
  ${FUN_BASE_DIR}/bin/mysqladmin  --socket=/tmp/node${FUN_NODE_NR}.socket -u root shutdown
  if [[ $? -ne 0 ]]; then
    echo "Shutdown failed for node${FUN_NODE_NR}"
    exit 1
  fi

  sleep 10

  echo "Starting PXC-${FUN_NODE_VER} node${FUN_NODE_NR} for upgrade"
  ${FUN_BASE_DIR}/bin/mysqld --no-defaults --defaults-group-suffix=.${FUN_NODE_NR} \
    --basedir=${FUN_BASE_DIR} --datadir=${FUN_NODE_PATH} \
    --loose-debug-sync-timeout=600 \
    --innodb_file_per_table --innodb_autoinc_lock_mode=2 \
    --wsrep-provider='none' --innodb_flush_method=O_DIRECT \
    --query_cache_type=0 --query_cache_size=0 \
    --innodb_flush_log_at_trx_commit=0 --innodb_buffer_pool_size=500M \
    --innodb_log_file_size=500M \
    --core-file --log_bin --binlog_format=ROW \
    --secure-file-priv= --loose-innodb-status-file=1 \
    --log-error=${FUN_LOG_ERR} \
    --socket=/tmp/node${FUN_NODE_NR}.socket --log-output=none \
    --port=${FUN_RBASE} --server-id=${FUN_NODE_NR} > ${FUN_LOG_ERR} 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${FUN_BASE_DIR}/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
      break
    fi
  done
  if ${FUN_BASE_DIR}/bin/mysqladmin -uroot -S/tmp/node${FUN_NODE_NR}.socket ping > /dev/null 2>&1; then
    echo "PXC node${FUN_NODE_NR} re-started for upgrade.."
  else
    echo "PXC node${FUN_NODE_NR} startup for upgrade failed... Please check error log: ${FUN_LOG_ERR}"
  fi

  sleep 10

  # Run mysql_upgrade
  ${FUN_BASE_DIR}/bin/mysql_upgrade -S /tmp/node${FUN_NODE_NR}.socket -u root >$WORKDIR/logs/mysql_upgrade_node${FUN_NODE_NR}.log 2>&1
  if [[ $? -ne 0 ]]; then
    echo "mysql upgrade on node${FUN_NODE_NR} failed"
    exit 1
  fi

  echo "Shutting down node${FUN_NODE_NR} after upgrade"
  ${FUN_BASE_DIR}/bin/mysqladmin  --socket=/tmp/node${FUN_NODE_NR}.socket -u root shutdown > /dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    echo "Shutdown after upgrade failed for node${FUN_NODE_NR}"
    exit 1
  fi
}

for BUILD_NUMBER in $(seq 1 ${NUMBEROFTRIALS}); do
  echo -e "\n\n*** TRIAL NUMBER: ${BUILD_NUMBER} ***\n"
  # User settings
  WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
  mkdir -p $WORKDIR/logs

  MYSQL_BASEDIR1="${ROOT_FS}/$BASE1"
  MYSQL_BASEDIR2="${ROOT_FS}/$BASE2"
  export MYSQL_VARDIR="$WORKDIR/mysqldir"
  mkdir -p $MYSQL_VARDIR

  echo "Workdir: $WORKDIR"
  echo "Basedirs: $MYSQL_BASEDIR1 $MYSQL_BASEDIR2"

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
  # Install cluster from previous version
  #
  echo -e "\n\n#### Installing cluster from previous version\n"
  ${MYSQL_BASEDIR1}/scripts/mysql_install_db --no-defaults --basedir=${MYSQL_BASEDIR1} --datadir=$node1 > $WORKDIR/logs/node1-pre.err 2>&1 || exit 1;
  pxc_start_node 1 "5.6" "$node1" "gcomm://" "gmcast.listen_addr=tcp://${LADDR1}" "$RBASE1" "${MYSQL_BASEDIR1}/lib/libgalera_smm.so" "$WORKDIR/logs/node1-pre.err" "${MYSQL_BASEDIR1}"

  ${MYSQL_BASEDIR1}/scripts/mysql_install_db --no-defaults --basedir=${MYSQL_BASEDIR1} --datadir=$node2 > $WORKDIR/logs/node2-pre.err 2>&1 || exit 1;
  pxc_start_node 2 "5.6" "$node2" "gcomm://$LADDR1" "gmcast.listen_addr=tcp://${LADDR2}" "$RBASE2" "${MYSQL_BASEDIR1}/lib/libgalera_smm.so" "$WORKDIR/logs/node2-pre.err" "${MYSQL_BASEDIR1}"

  #
  # Upgrading node2 to the new version
  #
  echo -e "\n\n#### Show node2 status before upgrade\n"
  show_node_status 2 $MYSQL_BASEDIR1 0
  echo "Running upgrade on node2"
  pxc_upgrade_node 2 "5.7" "$node2" "$RBASE2" "$WORKDIR/logs/node2-upgrade.err" "${MYSQL_BASEDIR2}"
  echo "Starting node2 after upgrade"
  pxc_start_node 2 "5.7" "$node2" "gcomm://$LADDR1" "gmcast.listen_addr=tcp://$LADDR2" "$RBASE2" "${MYSQL_BASEDIR2}/lib/libgalera_smm.so" "$WORKDIR/logs/node2-after_upgrade.err" "${MYSQL_BASEDIR2}"

  echo -e "\n\n#### Show node2 status after upgrade\n"
  show_node_status 2 $MYSQL_BASEDIR2 0
  #
  # End node2 upgrade and check
  #
  if [ $EXTSTATUS -ne 0 ]; then
    echo "Upgrade on node2 failed! Please check log files."
    break
  else
    echo -e "Upgrade successful!\n\n"
    pkill -9 mysqld >/dev/null 2>&1
    sleep 3
    rm -rf ${MYSQL_VARDIR}
  fi
done

exit $EXTSTATUS
