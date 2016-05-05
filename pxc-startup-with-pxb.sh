#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

# Edited by Shahriyar Rzayev, Percona LLC

# NOTE1
# This script should be run from PXC base dir!
# General usage in CentOS 7:
# wget http://jenkins.percona.com/job/pxc56.build/BUILD_TYPE=release,label_exp=centos7-64/lastSuccessfulBuild/artifact/target/Percona-XtraDB-Cluster-5.6.28-rel76.1-25.14..Linux.x86_64.tar.gz
# tar -xvf Percona-XtraDB-Cluster-5.6.28-rel76.1-25.14..Linux.x86_64.tar.gz
# cd Percona-XtraDB-Cluster-5.6.28-rel76.1-25.14..Linux.x86_64
# ../percona-qa/pxc-startup.sh

# NOTE2
# Dependency issue -> yum install socat unzip

#NOTE3
# With sst_method="xtrabackup"
#[ERROR] WSREP: Failed to read uuid:seqno from joiner script.
#[ERROR] WSREP: SST script aborted with error 32 (Broken pipe)
#[ERROR] WSREP: SST failed: 32 (Broken pipe)
#[ERROR] Aborting
# Fix is using sst_method="xtrabackup-v2"




BUILD=$(pwd)
SKIP_RQG_AND_BUILD_EXTRACT=0
sst_method="xtrabackup-v2"

# Ubuntu mysqld runtime provisioning
if [ "$(uname -v | grep 'Ubuntu')" != "" ]; then
  if [ "$(sudo apt-get -s install libaio1 | grep 'is already')" == "" ]; then
    sudo apt-get install libaio1 
  fi
  if [ "$(sudo apt-get -s install libjemalloc1 | grep 'is already')" == "" ]; then
    sudo apt-get install libjemalloc1
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libssl.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libssl.so.1.0.0 /lib/x86_64-linux-gnu/libssl.so.6
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libcrypto.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libcrypto.so.1.0.0 /lib/x86_64-linux-gnu/libcrypto.so.6
  fi
fi

PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`

if [[ $sst_method == "xtrabackup-v2" ]];then
  if [ ! -z $PXB_BASE ];then
    export PATH="$BUILD/$PXB_BASE/bin:$PATH"
  else

    if [ -f archive.zip ]; then
	unzip archive.zip
    else
	wget http://jenkins.percona.com/job/percona-xtrabackup-2.4-binary-tarball/label_exp=centos5-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
	unzip archive.zip
    fi

    tar -xzf archive/TARGET/*.tar.gz 
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$BUILD/$PXB_BASE/bin:$PATH"
  fi
fi

echo "Adding scripts: ./start_mtr | ./stop_mtr | ./node1_cl | ./node2_cl | ./node3_cl | ./wipe"

if [ ! -r $BUILD/mysql-test/mysql-test-run.pl ]; then
    echo "mysql test suite is not available, please check.."
fi


ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE1="$(( RPORT*1000 ))"
RADDR1="$ADDR:$(( RBASE1 + 7 ))"
LADDR1="$ADDR:$(( RBASE1 + 8 ))"

RBASE2="$(( RBASE1 + 100 ))"
RADDR2="$ADDR:$(( RBASE2 + 7 ))"
LADDR2="$ADDR:$(( RBASE2 + 8 ))"

RBASE3="$(( RBASE2 + 100 ))"
RADDR3="$ADDR:$(( RBASE3 + 7 ))"
LADDR3="$ADDR:$(( RBASE3 + 8 ))"

SUSER=root
SPASS=

node1="${BUILD}/node1"
mkdir -p $node1
node2="${BUILD}/node2"
mkdir -p $node2
node3="${BUILD}/node3"
mkdir -p $node3


echo "echo 'PXC startup script'" > ./start_mtr

echo "echo 'Starting PXC node1...'" >> ./start_mtr
echo "pushd ${BUILD}/mysql-test/" >> ./start_mtr

echo "set +e " >> ./start_mtr
echo " perl mysql-test-run.pl \\" >> ./start_mtr
echo "    --start-and-exit \\" >> ./start_mtr
echo "    --port-base=$RBASE1 \\" >> ./start_mtr
echo "    --nowarnings \\" >> ./start_mtr
echo "    --vardir=$node1 \\" >> ./start_mtr
echo "    --mysqld=--skip-performance-schema  \\" >> ./start_mtr
echo "    --mysqld=--innodb_file_per_table \\" >> ./start_mtr
echo "    --mysqld=--binlog-format=ROW \\" >> ./start_mtr
echo "    --mysqld=--wsrep-slave-threads=2 \\" >> ./start_mtr
echo "    --mysqld=--innodb_autoinc_lock_mode=2 \\" >> ./start_mtr
echo "    --mysqld=--innodb_locks_unsafe_for_binlog=1 \\" >> ./start_mtr
echo "    --mysqld=--wsrep-provider=${BUILD}/lib/libgalera_smm.so \\" >> ./start_mtr
echo "    --mysqld=--wsrep_cluster_address=gcomm:// \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_receive_address=$RADDR1 \\" >> ./start_mtr
echo "    --mysqld=--wsrep_node_incoming_address=$ADDR \\" >> ./start_mtr
echo "    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1" \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_method=$sst_method \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \\" >> ./start_mtr
echo "    --mysqld=--wsrep_node_address=$ADDR \\" >> ./start_mtr
echo "    --mysqld=--innodb_flush_method=O_DIRECT \\" >> ./start_mtr
echo "    --mysqld=--core-file \\" >> ./start_mtr
echo "    --mysqld=--loose-new \\" >> ./start_mtr
echo "    --mysqld=--sql-mode=no_engine_substitution \\" >> ./start_mtr
echo "    --mysqld=--loose-innodb \\" >> ./start_mtr
echo "    --mysqld=--secure-file-priv= \\" >> ./start_mtr
echo "    --mysqld=--loose-innodb-status-file=1 \\" >> ./start_mtr
echo "    --mysqld=--skip-name-resolve \\" >> ./start_mtr
echo "    --mysqld=--socket=$node1/socket.sock \\" >> ./start_mtr
echo "    --mysqld=--log-error=$node1/node.err \\" >> ./start_mtr
echo "    --mysqld=--log-output=none \\" >> ./start_mtr
echo "   1st" >> ./start_mtr
echo " set -e" >> ./start_mtr
echo "popd" >> ./start_mtr

echo "sleep 10" >> ./start_mtr

echo "echo 'Starting PXC node2...'" >> ./start_mtr
echo "pushd ${BUILD}/mysql-test/" >> ./start_mtr

echo "set +e " >> ./start_mtr
echo " perl mysql-test-run.pl \\" >> ./start_mtr
echo "    --start-and-exit \\" >> ./start_mtr
echo "    --port-base=$RBASE2 \\" >> ./start_mtr
echo "    --nowarnings \\" >> ./start_mtr
echo "    --vardir=$node2 \\" >> ./start_mtr
echo "    --mysqld=--skip-performance-schema  \\" >> ./start_mtr
echo "    --mysqld=--innodb_file_per_table  \\" >> ./start_mtr
echo "    --mysqld=--binlog-format=ROW \\" >> ./start_mtr
echo "    --mysqld=--wsrep-slave-threads=2 \\" >> ./start_mtr
echo "    --mysqld=--innodb_autoinc_lock_mode=2 \\" >> ./start_mtr
echo "    --mysqld=--innodb_locks_unsafe_for_binlog=1 \\" >> ./start_mtr
echo "    --mysqld=--wsrep-provider=${BUILD}/lib/libgalera_smm.so \\" >> ./start_mtr
echo "    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1 \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_receive_address=$RADDR2 \\" >> ./start_mtr
echo "    --mysqld=--wsrep_node_incoming_address=$ADDR \\" >> ./start_mtr
echo "    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2" \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_method=$sst_method \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \\" >> ./start_mtr
echo "    --mysqld=--wsrep_node_address=$ADDR \\" >> ./start_mtr
echo "    --mysqld=--innodb_flush_method=O_DIRECT \\" >> ./start_mtr
echo "    --mysqld=--core-file \\" >> ./start_mtr
echo "    --mysqld=--loose-new \\" >> ./start_mtr
echo "    --mysqld=--sql-mode=no_engine_substitution \\" >> ./start_mtr
echo "    --mysqld=--loose-innodb \\" >> ./start_mtr
echo "    --mysqld=--secure-file-priv= \\" >> ./start_mtr
echo "    --mysqld=--loose-innodb-status-file=1 \\" >> ./start_mtr
echo "    --mysqld=--skip-name-resolve \\" >> ./start_mtr
echo "    --mysqld=--socket=$node2/socket.sock \\" >> ./start_mtr
echo "    --mysqld=--log-error=$node2/node.err \\" >> ./start_mtr
echo "    --mysqld=--log-output=none \\" >> ./start_mtr
echo "   1st" >> ./start_mtr
echo " set -e" >> ./start_mtr
echo "popd" >> ./start_mtr

echo "sleep 5" >> ./start_mtr

echo "echo 'Starting PXC node3...'" >> ./start_mtr
echo "pushd ${BUILD}/mysql-test/" >> ./start_mtr

echo "set +e " >> ./start_mtr
echo " perl mysql-test-run.pl \\" >> ./start_mtr
echo "    --start-and-exit \\" >> ./start_mtr
echo "    --port-base=$RBASE3 \\" >> ./start_mtr
echo "    --nowarnings \\" >> ./start_mtr
echo "    --vardir=$node3 \\" >> ./start_mtr
echo "    --mysqld=--skip-performance-schema  \\" >> ./start_mtr
echo "    --mysqld=--innodb_file_per_table  \\" >> ./start_mtr
echo "    --mysqld=--binlog-format=ROW \\" >> ./start_mtr
echo "    --mysqld=--wsrep-slave-threads=2 \\" >> ./start_mtr
echo "    --mysqld=--innodb_autoinc_lock_mode=2 \\" >> ./start_mtr
echo "    --mysqld=--innodb_locks_unsafe_for_binlog=1 \\" >> ./start_mtr
echo "    --mysqld=--wsrep-provider=${BUILD}/lib/libgalera_smm.so \\" >> ./start_mtr
echo "    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_receive_address=$RADDR3 \\" >> ./start_mtr
echo "    --mysqld=--wsrep_node_incoming_address=$ADDR \\" >> ./start_mtr
echo "    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR3" \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_method=$sst_method \\" >> ./start_mtr
echo "    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \\" >> ./start_mtr
echo "    --mysqld=--wsrep_node_address=$ADDR \\" >> ./start_mtr
echo "    --mysqld=--innodb_flush_method=O_DIRECT \\" >> ./start_mtr
echo "    --mysqld=--core-file \\" >> ./start_mtr
echo "    --mysqld=--loose-new \\" >> ./start_mtr
echo "    --mysqld=--sql-mode=no_engine_substitution \\" >> ./start_mtr
echo "    --mysqld=--loose-innodb \\" >> ./start_mtr
echo "    --mysqld=--secure-file-priv= \\" >> ./start_mtr
echo "    --mysqld=--loose-innodb-status-file=1 \\" >> ./start_mtr
echo "    --mysqld=--skip-name-resolve \\" >> ./start_mtr
echo "    --mysqld=--socket=$node3/socket.sock \\" >> ./start_mtr
echo "    --mysqld=--log-error=$node3/node.err \\" >> ./start_mtr
echo "    --mysqld=--log-output=none \\" >> ./start_mtr
echo "   1st" >> ./start_mtr
echo " set -e" >> ./start_mtr
echo "popd" >> ./start_mtr

echo "${BUILD}/bin/mysqladmin -uroot -S$node3/socket.sock shutdown" > ./stop_mtr
echo "echo 'Server on socket $node3/socket.sock with datadir ${BUILD}/node3 halted'" >> ./stop_mtr
echo "${BUILD}/bin/mysqladmin -uroot -S$node2/socket.sock shutdown" >> ./stop_mtr
echo "echo 'Server on socket $node2/socket.sock with datadir ${BUILD}/node2 halted'" >> ./stop_mtr
echo "${BUILD}/bin/mysqladmin -uroot -S$node1/socket.sock shutdown" >> ./stop_mtr
echo "echo 'Server on socket $node1/socket.sock with datadir ${BUILD}/node1 halted'" >> ./stop_mtr

echo "if [ -r ./stop_mtr ]; then ./stop_mtr 2>/dev/null 1>&2; fi" > ./wipe
echo "if [ -d $BUILD/node1.PREV ]; then rm -Rf $BUILD/node1.PREV.older; mv $BUILD/node1.PREV $BUILD/node1.PREV.older; fi;mv $BUILD/node1 $BUILD/node1.PREV" >> ./wipe
echo "if [ -d $BUILD/node2.PREV ]; then rm -Rf $BUILD/node2.PREV.older; mv $BUILD/node2.PREV $BUILD/node2.PREV.older; fi;mv $BUILD/node2 $BUILD/node2.PREV" >> ./wipe
echo "if [ -d $BUILD/node3.PREV ]; then rm -Rf $BUILD/node3.PREV.older; mv $BUILD/node3.PREV $BUILD/node3.PREV.older; fi;mv $BUILD/node3 $BUILD/node3.PREV" >> ./wipe

echo "$BUILD/bin/mysql -A -uroot -S$node1/socket.sock test" > ./node1_cl
echo "$BUILD/bin/mysql -A -uroot -S$node2/socket.sock test" > ./node2_cl
echo "$BUILD/bin/mysql -A -uroot -S$node3/socket.sock test" > ./node3_cl

chmod +x ./start_mtr ./stop_mtr ./node1_cl ./node2_cl ./node3_cl ./wipe

