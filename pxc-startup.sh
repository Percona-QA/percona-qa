#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

BUILD=$(pwd)
SKIP_RQG_AND_BUILD_EXTRACT=0
sst_method="rsync"

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

if [[ $sst_method == "xtrabackup" ]];then
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

echo "Adding scripts: ./start_pxc | ./ stop_pxc | ./node1_cl | ./node2_cl | ./node3_cl | ./wipe"

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
node2="${BUILD}/node2"
node3="${BUILD}/node3"

keyring_node1="${BUILD}/keyring_node1"
keyring_node2="${BUILD}/keyring_node2"
keyring_node3="${BUILD}/keyring_node3"

if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
  mkdir -p $node1 $node2 $node3
  mkdir -p $keyring_node1 $keyring_node2 $keyring_node3
fi

echo "PXC_MYEXTRA=\"\"" > ./start_pxc
echo "PXC_START_TIMEOUT=300"  >> ./start_pxc
echo "KEY_RING_OPTIONS=0"  >> ./start_pxc
echo -e "\n" >> ./start_pxc
echo "echo 'Starting PXC nodes..'" >> ./start_pxc
echo -e "\n" >> ./start_pxc

echo "if [ \"$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)\" == \"5.7\" ]; then" >> ./start_pxc
echo "  MID=\"${BUILD}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BUILD}\"" >> ./start_pxc
echo "  KEY_RING_OPTIONS=1" >> ./start_pxc
echo "elif [ \"$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)\" == \"5.6\" ]; then" >> ./start_pxc
echo "  MID=\"${BUILD}/scripts/mysql_install_db --no-defaults --basedir=${BUILD}\"" >> ./start_pxc
echo "fi" >> ./start_pxc

echo -e "\n" >> ./start_pxc

echo "\${MID} --datadir=$node1  > ${BUILD}/startup_node1.err 2>&1 || exit 1;" >> ./start_pxc

echo -e "\n" >> ./start_pxc

echo "${BUILD}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \\" >> ./start_pxc
echo "    --basedir=${BUILD} --datadir=$node1 \\" >> ./start_pxc
echo "    --loose-debug-sync-timeout=600 --skip-performance-schema \\" >> ./start_pxc
echo "    --innodb_file_per_table \$PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \\" >> ./start_pxc
echo "    --wsrep-provider=${BUILD}/lib/libgalera_smm.so \\" >> ./start_pxc
echo "    --wsrep_cluster_address=gcomm:// \\" >> ./start_pxc
echo "    --wsrep_node_incoming_address=$ADDR \\" >> ./start_pxc
echo "    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \\" >> ./start_pxc
echo "    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \\" >> ./start_pxc
echo "    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \\" >> ./start_pxc
echo "    --core-file --loose-new --sql-mode=no_engine_substitution \\" >> ./start_pxc
echo "    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \\" >> ./start_pxc
echo "    --log-error=$node1/node1.err \\" >> ./start_pxc
if [ $KEY_RING_OPTIONS -eq 1 ];
  echo "    --early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node1/keyring \\" >> ./start_pxc
fi
echo "    --early-plugin-load=keyring_file.so \\" >> ./start_pxc
echo "    --keyring_file_data=$keyring_node1/keyring \\" >> ./start_pxc
echo "    --socket=$node1/socket.sock --log-output=none \\" >> ./start_pxc
echo "    --port=$RBASE1 --server-id=1 --wsrep_slave_threads=2 > $node1/node1.err 2>&1 &" >> ./start_pxc

echo -e "\n" >> ./start_pxc
echo "for X in $(seq 0 ${PXC_START_TIMEOUT}); do" >> ./start_pxc
echo "  sleep 1" >> ./start_pxc
echo "  if ${BASEDIR}/bin/mysqladmin -uroot -S$node1/socket.sock ping > /dev/null 2>&1; then" >> ./start_pxc
echo "    break" >> ./start_pxc
echo "  fi" >> ./start_pxc
echo "done" >> ./start_pxc

echo -e "\n\n" >> ./start_pxc
echo "\${MID} --datadir=$node2  > ${BUILD}/startup_node2.err 2>&1 || exit 1;" >> ./start_pxc

echo -e "\n" >> ./start_pxc

echo "${BUILD}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \\" >> ./start_pxc
echo "    --basedir=${BUILD} --datadir=$node2 \\" >> ./start_pxc
echo "    --loose-debug-sync-timeout=600 --skip-performance-schema \\" >> ./start_pxc
echo "    --innodb_file_per_table \$PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \\" >> ./start_pxc
echo "    --wsrep-provider=${BUILD}/lib/libgalera_smm.so \\" >> ./start_pxc
echo "    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR3 \\" >> ./start_pxc
echo "    --wsrep_node_incoming_address=$ADDR \\" >> ./start_pxc
echo "    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 \\" >> ./start_pxc
echo "    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \\" >> ./start_pxc
echo "    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \\" >> ./start_pxc
echo "    --core-file --loose-new --sql-mode=no_engine_substitution \\" >> ./start_pxc
echo "    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \\" >> ./start_pxc
echo "    --log-error=$node2/node2.err \\" >> ./start_pxc
if [ $KEY_RING_OPTIONS -eq 1 ];
  echo "    --early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node2/keyring \\" >> ./start_pxc
fi
echo "    --socket=$node2/socket.sock --log-output=none \\" >> ./start_pxc
echo "    --port=$RBASE2 --server-id=2 --wsrep_slave_threads=2 > $node2/node2.err 2>&1 &" >> ./start_pxc

echo -e "\n" >> ./start_pxc

echo "for X in $(seq 0 ${PXC_START_TIMEOUT}); do" >> ./start_pxc
echo "  sleep 1" >> ./start_pxc
echo "  if ${BUILD}/bin/mysqladmin -uroot -S$node2/socket.sock ping > /dev/null 2>&1; then" >> ./start_pxc
echo "    break" >> ./start_pxc
echo "  fi" >> ./start_pxc
echo "done" >> ./start_pxc

echo -e "\n\n" >> ./start_pxc
echo "\${MID} --datadir=$node3  > ${BUILD}/startup_node2.err 2>&1 || exit 1;" >> ./start_pxc

echo -e "\n" >> ./start_pxc

echo "${BUILD}/bin/mysqld --no-defaults --defaults-group-suffix=.1 \\" >> ./start_pxc
echo "    --basedir=${BUILD} --datadir=$node3 \\" >> ./start_pxc
echo "    --loose-debug-sync-timeout=600 --skip-performance-schema \\" >> ./start_pxc
echo "    --innodb_file_per_table \$PXC_MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \\" >> ./start_pxc
echo "    --wsrep-provider=${BUILD}/lib/libgalera_smm.so \\" >> ./start_pxc
echo "    --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2 \\" >> ./start_pxc
echo "    --wsrep_node_incoming_address=$ADDR \\" >> ./start_pxc
echo "    --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR3 \\" >> ./start_pxc
echo "    --wsrep_sst_method=rsync --wsrep_sst_auth=$SUSER:$SPASS \\" >> ./start_pxc
echo "    --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT \\" >> ./start_pxc
echo "    --core-file --loose-new --sql-mode=no_engine_substitution \\" >> ./start_pxc
echo "    --loose-innodb --secure-file-priv= --loose-innodb-status-file=1 \\" >> ./start_pxc
echo "    --log-error=$node3/node3.err \\" >> ./start_pxc
if [ $KEY_RING_OPTIONS -eq 1 ];
  echo "    --early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node3/keyring \\" >> ./start_pxc
fi
echo "    --socket=$node3/socket.sock --log-output=none \\" >> ./start_pxc
echo "    --port=$RBASE3 --server-id=3 --wsrep_slave_threads=2 > $node3/node3.err 2>&1 &" >> ./start_pxc

echo -e "\n" >> ./start_pxc

echo "for X in $(seq 0 ${PXC_START_TIMEOUT}); do" >> ./start_pxc
echo "  sleep 1" >> ./start_pxc
echo "  if ${BUILD}/bin/mysqladmin -uroot -S$node3/socket.sock ping > /dev/null 2>&1; then" >> ./start_pxc
echo "    ${BUILD}/bin/mysql -uroot -S$node1/socket.sock -e\"drop database if exists test;create database test;\"" >> ./start_pxc
echo "    break" >> ./start_pxc
echo "  fi" >> ./start_pxc
echo "done" >> ./start_pxc
echo -e "\n\n" >> ./start_pxc

echo "${BUILD}/bin/mysqladmin -uroot -S$node3/socket.sock shutdown" > ./stop_pxc
echo "echo 'Server on socket $node3/socket.sock with datadir ${BUILD}/node3 halted'" >> ./stop_pxc
echo "${BUILD}/bin/mysqladmin -uroot -S$node2/socket.sock shutdown" >> ./stop_pxc
echo "echo 'Server on socket $node2/socket.sock with datadir ${BUILD}/node2 halted'" >> ./stop_pxc
echo "${BUILD}/bin/mysqladmin -uroot -S$node1/socket.sock shutdown" >> ./stop_pxc
echo "echo 'Server on socket $node1/socket.sock with datadir ${BUILD}/node1 halted'" >> ./stop_pxc

echo "if [ -r ./stop_pxc ]; then ./stop_pxc 2>/dev/null 1>&2; fi" > ./wipe
echo "if [ -d $BUILD/node1.PREV ]; then rm -Rf $BUILD/node1.PREV.older; mv $BUILD/node1.PREV $BUILD/node1.PREV.older; fi;mv $BUILD/node1 $BUILD/node1.PREV" >> ./wipe
echo "if [ -d $BUILD/node2.PREV ]; then rm -Rf $BUILD/node2.PREV.older; mv $BUILD/node2.PREV $BUILD/node2.PREV.older; fi;mv $BUILD/node2 $BUILD/node2.PREV" >> ./wipe
echo "if [ -d $BUILD/node3.PREV ]; then rm -Rf $BUILD/node3.PREV.older; mv $BUILD/node3.PREV $BUILD/node3.PREV.older; fi;mv $BUILD/node3 $BUILD/node3.PREV" >> ./wipe

echo "$BUILD/bin/mysql -A -uroot -S$node1/socket.sock" > ./node1_cl
echo "$BUILD/bin/mysql -A -uroot -S$node2/socket.sock" > ./node2_cl
echo "$BUILD/bin/mysql -A -uroot -S$node3/socket.sock" > ./node3_cl

chmod +x ./start_pxc ./stop_pxc ./node1_cl ./node2_cl ./node3_cl ./wipe
