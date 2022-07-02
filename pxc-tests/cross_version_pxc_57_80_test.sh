#!/bin/bash

###############################################################################################
#                                                                                             #
# Author  :  Mohit Joshi                                                                      #
# Script  :  cross_version_pxc_57_80_test.sh                                                  #
# Created :  28-June-2022                                                                     #
# Purpose :  The script attempts to connect a PXC 8.0  node to an existing PXC-5.7 cluster    #
#            and run some load using sysbench and verify data is replicated successfully      #
#                                                                                             #
# Usage   :  ./cross_version_pxc_57_80_test.sh /path/PXC-5.7/tarball /path/PXC-8.0/tarball    #
#                                                                                             #
# Note    : The script supports only debug/release tarballs. In case, you intend to run the   #
#           script on a manual build, copy the galera libraries to $BUILD/lib directory. In   #
#           case `lib` directory does not exists                                              #
#                                                                                             #
#           mkdir $BUILD_57/lib                                                               #
#           cp /path/to/built/libgalera_smm.so $BUILD_57/lib                                  #
###############################################################################################

BUILD_57=$(realpath $1)
BUILD_80=$(realpath $2)

PXC_START_TIMEOUT=120

# Sysbench Internal variables
SYS_TABLES=50
SYS_DURATION=60
SYS_THREADS=5

# Check if xtrabackup 2.4 or 8.0 is installed
echo "...Looking for xtrabackup package installed on the machine"
if [[ ! -e `which xtrabackup` ]]; then
  echo "Xtrabackup not found"
  echo "...Installing percona-xtrabackup-24 package"
  sudo percona-release enable tools release > /dev/null 2>&1
  sudo apt-get install percona-xtrabackup-24 > /dev/null 2>&1
  echo "Xtrabackup installed successfully"
else
  echo "Xtrabackup found at $(which xtrabackup)"
  xtrabackup --version
fi

# Check if sysbench is installed
echo "...Looking for sysbench installed on the machine"
if [[ ! -e `which sysbench` ]]; then
  echo "Sysbench not found"
  echo "...Installing sysbench"
  sudo apt-get install sysbench > /dev/null 2>&1
  echo "Sysbench installed successfully"
else
  echo "Sysbench found at: $(which sysbench)"
fi

echo "Basedir 57 has been set to: $BUILD_57";
echo "Basedir 80 has been set to: $BUILD_80";

echo "Killing old mysqld instances"
pkill -9 mysqld 2>/dev/null

if [ -d $BUILD_57/pxc-node ]; then
  echo "...Found existing PXC nodes."
  rm -rf $BUILD_57/pxc-node
  echo "Removed"
fi

if [ -d $BUILD_80/pxc-node ]; then
  echo "...Found existing PXC nodes."
  rm -rf $BUILD_80/pxc-node
  echo "Removed"
fi

for X in $(seq 1 2); do
  echo "...Creating work directory for $X"
  if [ $X -eq 1 ]; then
    WORKDIR_57=$BUILD_57/pxc-node
    mkdir $WORKDIR_57
    mkdir $WORKDIR_57/cert
    echo "Workdir has been set to: $WORKDIR_57"
    SOCKET_57=$WORKDIR_57/dn_57/mysqld_57.sock
    ERR_FILE_57=$WORKDIR_57/node1.err
  else
    WORKDIR_80=$BUILD_80/pxc-node
    mkdir $WORKDIR_80
    mkdir $WORKDIR_80/cert
    echo "Workdir has been set to: $WORKDIR_80"
    SOCKET_80=$WORKDIR_80/dn_80/mysqld_80.sock
    ERR_FILE_80=$WORKDIR_80/node2.err
  fi
done

if [ ! -e $BUILD_57/lib/libgalera_smm.so ]; then
  echo "ERROR: libgalera_smm.so not found. Check for missing library in $BUILD_57/lib/"
  exit 1
fi
if [ ! -e $BUILD_80/lib/libgalera_smm.so ]; then
  echo "ERROR: libgalera_smm.so not found. Check for missing library in $BUILD_80/lib"
  exit 1
fi

echo "
[mysqld]

port = 4000
server-id=1
log-error-verbosity=3
core-file

# file paths
basedir=$BUILD_57/
datadir=$BUILD_57/pxc-node/dn_57
log-error=$BUILD_57/pxc-node/node1.err
general_log=1
general_log_file=$BUILD_57/pxc-node/dn_57/general.log
slow_query_log=1
slow_query_log_file=$BUILD_57/pxc-node/dn_57/slow.log
socket=$SOCKET_57
character-sets-dir=$BUILD_57/share/charsets
lc-messages-dir=$BUILD_57/share/

# pxc variables
log_bin=binlog
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=OFF

# wsrep variables
wsrep_sst_auth=root:
wsrep_cluster_address='gcomm://127.0.0.1:5030'
wsrep_provider=$BUILD_57/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node4000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR_57/cert/ca.pem
ssl-cert = $WORKDIR_57/cert/server-cert.pem
ssl-key = $WORKDIR_57/cert/server-key.pem
[client]
ssl-ca = $WORKDIR_57/cert/ca.pem
ssl-cert = $WORKDIR_57/cert/client-cert.pem
ssl-key = $WORKDIR_57/cert/client-key.pem
[sst]
encrypt = 0
ssl-ca = $WORKDIR_57/cert/ca.pem
ssl-cert = $WORKDIR_57/cert/server-cert.pem
ssl-key = $WORKDIR_57/cert/server-key.pem


" > $WORKDIR_57/n1.cnf

echo "
[mysqld]

port = 5000
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BUILD_80/
datadir=$BUILD_80/pxc-node/dn_80
log-error=$BUILD_80/pxc-node/node2.err
general_log=1
general_log_file=$BUILD_80/pxc-node/dn_80/general.log
slow_query_log=1
slow_query_log_file=$BUILD_80/pxc-node/dn_80/slow.log
socket=$SOCKET_80
character-sets-dir=$BUILD_80/share/charsets
lc-messages-dir=$BUILD_80/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=OFF

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:4030'
wsrep_provider=$BUILD_80/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:5020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node5000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR_80/cert/ca.pem
ssl-cert = $WORKDIR_80/cert/server-cert.pem
ssl-key = $WORKDIR_80/cert/server-key.pem
[client]
ssl-ca = $WORKDIR_80/cert/ca.pem
ssl-cert = $WORKDIR_80/cert/client-cert.pem
ssl-key = $WORKDIR_80/cert/client-key.pem
[sst]
encrypt = 0
ssl-ca = $WORKDIR_80/cert/ca.pem
ssl-cert = $WORKDIR_80/cert/server-cert.pem
ssl-key = $WORKDIR_80/cert/server-key.pem

" > $WORKDIR_80/n2.cnf

fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    SOCKET=$SOCKET_57
    ERR_FILE=$ERR_FILE_57
  else
    SOCKET=$SOCKET_80
    ERR_FILE=$ERR_FILE_80
  fi
}

pxc_startup_status(){
  NR=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if [ $NR -eq 1 ]; then
      if $BUILD_57/bin/mysqladmin -uroot -S$SOCKET_57 ping > /dev/null 2>&1; then
        echo "Node $NR started successfully"
        break
      fi
    else
      if $BUILD_80/bin/mysqladmin -uroot -S$SOCKET_80 ping > /dev/null 2>&1; then
        echo "Node $NR started successfully"
        break
      fi
    fi

    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
      if [ $NR -eq 1 ]; then
        echo "ERROR: Node $NR failed to start. Check Error logs: $WORKDIR_57/node1.err"
        exit 1
      else
        echo "ERROR: Node $NR failed to start. Check Error logs: $WORKDIR_80/node2.err"
        exit 1
      fi
    fi
  done
}

echo "...Creating data directories"
$BUILD_57/bin/mysqld --no-defaults --datadir=$BUILD_57/pxc-node/dn_57 --basedir=$BUILD_57 --initialize-insecure --log-error=$BUILD_57/pxc-node/node1.err 
echo "Data directory for PXC-5.7 created"

$BUILD_80/bin/mysqld --no-defaults --datadir=$BUILD_80/pxc-node/dn_80 --basedir=$BUILD_80 --initialize-insecure --log-error=$BUILD_80/pxc-node/node2.err
echo "Data directory for PXC-8.0 created"

cp $WORKDIR_57/dn_57/*.pem $WORKDIR_57/cert/
cp $WORKDIR_80/dn_80/*.pem $WORKDIR_80/cert/

echo "...Starting PXC nodes"
fetch_err_socket 1
$BUILD_57/bin/mysqld --defaults-file=$BUILD_57/pxc-node/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
pxc_startup_status 1

fetch_err_socket 2
$BUILD_80/bin/mysqld --defaults-file=$BUILD_80/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

echo "...Checking 2 node PXC Cluster startup"
for X in $(seq 1 10); do
  sleep 1
  CLUSTER_UP=0;
  if $BUILD_57/bin/mysqladmin -uroot -S$SOCKET_57 ping > /dev/null 2>&1; then
    if [ `$BUILD_57/bin/mysql -uroot -S$SOCKET_57 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `$BUILD_80/bin/mysql -uroot -S$SOCKET_80 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`$BUILD_57/bin/mysql -uroot -S$SOCKET_57 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`$BUILD_80/bin/mysql -uroot -S$SOCKET_80 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
  fi
  # If count reached 4 (there are 4 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 4 ]; then
    echo "2 Node PXC Cluster started ok. Clients:"
    echo "Node #1: `echo $BUILD_57/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_57"
    echo "Node #2: `echo $BUILD_80/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_80"
    break
  fi
  if [ $X -eq 10 ]; then
    echo "Server may have started, but the cluster does not seem to be in a consistent state"
    echo "Check Error logs for more info:"
    echo "$WORKDIR_57/node1.err"
    echo "$WORKDIR_80/node2.err"
  fi
done

echo "...Creating sysbench user"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57 -e"CREATE USER 'sysbench'@'localhost' IDENTIFIED BY 'test'"
echo "Successful"
echo "...Granting permissions to sysbench user"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57 -e"GRANT ALL ON *.* TO 'sysbench'@'localhost'"
echo "Successful"
echo "...Creating sbtest database"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57 -e"DROP DATABASE IF EXISTS sbtest"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57 -e"CREATE DATABASE sbtest"
echo "Successful"

echo "...Preparing sysbench data on Node 1"
sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_57 --threads=$SYS_THREADS --tables=$SYS_TABLES --table-size=100 prepare > /dev/null 2>&1
echo "Data loaded successfully"
echo "...Running sysbench load on Node 1 for $SYS_DURATION seconds"
sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_57 --threads=$SYS_THREADS --tables=$SYS_TABLES --time=$SYS_DURATION --report-interval=1 --events=1870000000 --db-ps-mode=disable run > /dev/null 2>&1
echo "Sysbench run successful"

# Wait for the nodes sync
sleep 2;
echo "...Random verification of table counts"
for X in $(seq 1 10); do
  RAND=$[$RANDOM%50 + 1 ]
  # -N suppresses column names and -s is silent mode
  count_57=$($BUILD_57/bin/mysql -uroot -S$SOCKET_57 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  count_80=$($BUILD_80/bin/mysql -uroot -S$SOCKET_80 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  if [ $count_57 -eq $count_80 ]; then
   echo "Data replicated and matched successfully sbtest$RAND count: $count_57 = $count_80"
  else
   echo "ERROR: Data mismatch found. sbtest$RAND count: $count_57 = $count_80"
   exit 1
  fi
done
