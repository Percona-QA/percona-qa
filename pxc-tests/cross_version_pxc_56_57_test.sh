#!/bin/bash

###############################################################################################
#                                                                                             #
# Author  :  Mohit Joshi                                                                      #
# Script  :  cross_version_pxc_56_57_test.sh                                                  #
# Created :  24-June-2022                                                                     #
# Purpose :  The script attempts to connect a PXC 5.7 node to an existing PXC-5.6 cluster     #
#            and run some load using sysbench and verify data is replicated successfully      #
#                                                                                             #
# Usage   :  ./cross_version_pxc_56_57_test.sh <PXC-5.6/install/path> <PXC-5.7/install/path>  #
#                                                                                             #
###############################################################################################

BASEDIR_56=$(realpath $1)
BASEDIR_57=$(realpath $2)

PXC_START_TIMEOUT=30

# Sysbench Internal variables
SYS_TABLES=50
SYS_DURATION=60
SYS_THREADS=5

# Check if xtrabackup 2.4 is installed
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

echo "Killing old mysqld instances"
pkill -9 mysqld 2>/dev/null
echo "Basedir 56 has been set to: $BASEDIR_56";
echo "Basedir 57 has been set to: $BASEDIR_57";

if [ -d $BASEDIR_56/pxc-node ]; then
  echo "...Found existing work directory for PXC-5.6"
  rm -rf $BASEDIR_56/pxc-node
  echo "Removed"
fi

if [ -d $BASEDIR_57/pxc-node ]; then
  echo "...Found existing work directory for PXC-5.7"
  rm -rf $BASEDIR_57/pxc-node
  echo "Removed"
fi

for X in $(seq 1 2); do
  if [ $X -eq 1 ]; then
    echo "...Creating work directory for PXC-5.6"
    WORKDIR_56=$BASEDIR_56/pxc-node
    mkdir $WORKDIR_56
    echo "Workdir has been set to: $WORKDIR_56" 
    SOCKET_56=$WORKDIR_56/dn_56/mysqld_56.sock
    ERR_FILE_56=$WORKDIR_56/node1.err
  else
    echo "...Creating work directory for PXC-5.7"
    WORKDIR_57=$BASEDIR_57/pxc-node
    mkdir $WORKDIR_57
    echo "Workdir has been set to: $WORKDIR_57" 
    SOCKET_57=$WORKDIR_57/dn_57/mysqld_57.sock
    ERR_FILE_57=$WORKDIR_57/node2.err
  fi
done

echo "...Creating n1.cnf for PXC-5.6"
echo "
[mysqld]

port = 4000
socket=$SOCKET_56
server-id=1
core-file

# file paths
basedir=$BASEDIR_56/
datadir=$BASEDIR_56/pxc-node/dn_56
plugin_dir=$BASEDIR_56/lib/plugin/
log-error=$BASEDIR_56/pxc-node/node1.err
general_log=1
general_log_file=$BASEDIR_56/pxc-node/dn_56/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR_56/pxc-node/dn_56/slow.log

character-sets-dir=$BASEDIR_56/share/charsets
lc-messages-dir=$BASEDIR_56/share/

# pxc variables
log_bin=binlog
log-slave-updates=1
binlog_format=ROW
master_verify_checksum=on
binlog_checksum=CRC32
gtid_mode=ON
enforce_gtid_consistency=ON

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:5030'
wsrep_cluster_name=my_pxc

wsrep_provider=$BASEDIR_56/../../percona-xtradb-cluster-galera/libgalera_smm.so

wsrep_node_incoming_address=127.0.0.1
wsrep_node_name=node4000

wsrep_sst_auth=root:
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_sst_method=xtrabackup-v2
wsrep_debug=1

wsrep_slave_threads=2
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;\"
innodb_autoinc_lock_mode=2

[sst]
wsrep_debug=1

" > $WORKDIR_56/n1.cnf

echo "OK"

echo "...Creating n2.cnf for PXC-5.7"
echo "
[mysqld]

port = 5000
socket=$SOCKET_57
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR_57/
datadir=$BASEDIR_57/pxc-node/dn_57
plugin_dir=$BASEDIR_57/lib/plugin
log-error=$BASEDIR_57/pxc-node/node2.err
general_log=1
general_log_file=$BASEDIR_57/pxc-node/dn_57/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR_57/pxc-node/dn_57/slow.log
character-sets-dir=$BASEDIR_57/share/charsets
lc-messages-dir=$BASEDIR_57/share/

# pxc variables
log_bin=binlog
binlog_format=ROW
log-slave-updates=1
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=OFF

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:4030'
wsrep_cluster_name=my_pxc

wsrep_provider=$BASEDIR_57/../../percona-xtradb-cluster-galera/libgalera_smm.so

wsrep_node_incoming_address=127.0.0.1
wsrep_node_name=node5000

wsrep_sst_receive_address=127.0.0.1:5020
wsrep_sst_method=xtrabackup-v2

wsrep_slave_threads=2
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;\"
innodb_autoinc_lock_mode=2
wsrep_debug=1

[sst]
wsrep_debug=1
" > $WORKDIR_57/n2.cnf

echo "OK"

fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    SOCKET=$SOCKET_56
    ERR_FILE=$ERR_FILE_56
  else
    SOCKET=$SOCKET_57
    ERR_FILE=$ERR_FILE_57
  fi
}

pxc_startup_status(){
  NR=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if [ $NR -eq 1 ]; then
      if $BASEDIR_56/bin/mysqladmin -uroot -S$SOCKET_56 ping > /dev/null 2>&1; then
	echo "Node $NR started successfully"
        break
      fi
    else
      if $BASEDIR_57/bin/mysqladmin -uroot -S$SOCKET_57 ping > /dev/null 2>&1; then
	echo "Node $NR started successfully"
        break
      fi
    fi
    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
      if [ $NR -eq 1 ]; then
        echo "ERROR: Node $NR failed to start. Check Error logs: $WORKDIR_56/node1.err"
        exit 1
      else
        echo "ERROR: Node $NR failed to start. Check Error logs: $WORKDIR_57/node2.err"
        exit 1
      fi
    fi
  done
}

echo "...Creating data directories"
$BASEDIR_56/scripts/mysql_install_db --no-defaults --datadir=$BASEDIR_56/pxc-node/dn_56 --basedir=$BASEDIR_56 --log-error=$BASEDIR_56/pxc-node/node1.err > /dev/null 2>&1
$BASEDIR_57/bin/mysqld --no-defaults --datadir=$BASEDIR_57/pxc-node/dn_57 --basedir=$BASEDIR_57 --initialize-insecure --log-error=$BASEDIR_57/pxc-node/node2.err > /dev/null 2>&1
echo "Data directories created"

echo "...Starting PXC node1"
fetch_err_socket 1
$BASEDIR_56/bin/mysqld --defaults-file=$BASEDIR_56/pxc-node/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
pxc_startup_status 1

echo "...Starting PXC node2"
fetch_err_socket 2
$BASEDIR_57/bin/mysqld --defaults-file=$BASEDIR_57/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

echo "Upgrade PXC 5.7 server as currently it has SST data from PXC 5.6"
$BASEDIR_57/bin/mysql_upgrade -uroot -h127.0.0.1 -P5000 > /dev/null 2>&1
sleep 20;

echo "...Shutting down PXC 5.7 to restart with upgraded data directory"
$BASEDIR_57/bin/mysqladmin -uroot -h127.0.0.1 -P5000 shutdown > /dev/null 2>&1
sleep 20; 

echo "...Starting PXC node2"
fetch_err_socket 2
$BASEDIR_57/bin/mysqld --defaults-file=$BASEDIR_57/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

echo "...Checking if PXC Cluster started"
for X in $(seq 1 10); do
  sleep 1
  CLUSTER_UP=0;
  if $BASEDIR_56/bin/mysqladmin -uroot -S$SOCKET_56 ping > /dev/null 2>&1; then
    if [ `$BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then 
	    CLUSTER_UP=$((CLUSTER_UP + 1))
    fi
    if [ `$BASEDIR_57/bin/mysql -uroot -S$SOCKET_57 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then 
	    CLUSTER_UP=$((CLUSTER_UP + 1))
    fi
    if [ "`$BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then 
	    CLUSTER_UP=$((CLUSTER_UP + 1))
    fi
    if [ "`$BASEDIR_57/bin/mysql -uroot -S$SOCKET_57 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then 
	    CLUSTER_UP=$((CLUSTER_UP + 1))
    fi
  fi
  # If count reached 4 (there are 4 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 4 ]; then
    echo "2 Node PXC Cluster started ok. Clients:"
    echo "Node #1: `echo $BASEDIR_56/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_56"
    echo "Node #2: `echo $BASEDIR_57/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_57"
    break
  fi
  if [ $X -eq 10 ]; then
    echo "Server may have started, but the cluster does not seem to be in a consistent state"
    echo "Check Error logs for more info:"
    echo "$WORKDIR_56/node1.err"
    echo "$WORKDIR_57/node2.err"
  fi
done

echo "...Creating sysbench user"
$BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -e"CREATE USER 'sysbench'@'localhost' IDENTIFIED BY 'test'"
echo "Successful"
echo "...Granting permissions to sysbench user"
$BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -e"GRANT ALL ON *.* TO 'sysbench'@'localhost'"
echo "Successful"
echo "...Creating sbtest database"
$BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -e"DROP DATABASE IF EXISTS sbtest"
$BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -e"CREATE DATABASE sbtest"
echo "Successful"

echo "...Preparing sysbench data on Node 1"
sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_56 --threads=$SYS_THREADS --tables=$SYS_TABLES --table-size=100 prepare > /dev/null 2>&1
echo "Data loaded successfully"
echo "...Running sysbench load on Node 1 for $SYS_DURATION seconds"
sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_56 --threads=$SYS_THREADS --tables=$SYS_TABLES --time=$SYS_DURATION --report-interval=1 --events=1870000000 --db-ps-mode=disable run > /dev/null 2>&1
echo "Sysbench run successful"

# Wait for the nodes sync
sleep 2;
echo "...Random verification of table counts"
for X in $(seq 1 10); do
  RAND=$[$RANDOM%50 + 1 ]
  # -N suppresses column names and -s is silent mode
  count_56=$($BASEDIR_56/bin/mysql -uroot -S$SOCKET_56 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  count_57=$($BASEDIR_57/bin/mysql -uroot -S$SOCKET_57 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  if [ $count_56 -eq $count_57 ]; then
   echo "Data replicated and matched successfully sbtest$RAND count: $count_56 = $count_57"
  else
   echo "Data mismatch found. sbtest$RAND count: $count_56 = $count_57"
   echo "Exiting.."
   exit 1
  fi
done

