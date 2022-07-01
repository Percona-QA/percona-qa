#!/bin/bash

#######################################################################################################
#                                                                                                     #
# Author  :  Mohit Joshi                                                                              #
# Script  :  cross_version_pxc_57_80_upgrade_test.sh                                                  #
# Created :  01-July-2022                                                                             #
# Purpose :  The script attempts to test upgrade scenarios from PXC-5.7 cluster to PXC-8.0            #
#            and run some load using sysbench and verify data is replicated successfully              #
#                                                                                                     #
# Usage   :  ./cross_version_pxc_57_80_upgrade_test.sh /path/PXC-5.7/tarball /path/PXC-8.0/tarball    #
#                                                                                                     #
# Note    : The script supports only debug/release tarballs. In case, you intend to run the           #
#           script on a manual build, copy the galera libraries to $BUILD/lib directory. In           #
#           case `lib` directory does not exists                                                      #
#                                                                                                     #
#           mkdir $BUILD_57/lib                                                                       #
#           cp /path/to/built/libgalera_smm.so $BUILD_57/lib                                          #
#######################################################################################################

BUILD_57=$(realpath $1)
BUILD_80=$(realpath $2)

#################################################################################################
# Some machines (like CentOS-7) on Jenkins may take upto 2 mins for the cluster to start. Hence #
# do not change the value. In case, the server starts early the script does not wait until the  #
# timeout period.                                                                               #
#################################################################################################
PXC_START_TIMEOUT=120

# Sysbench Internal variables
SYS_TABLES=50
SYS_DURATION=60
SYS_THREADS=5

# Check if Build paths are valid
if [ ! -d "$BUILD_57" -o ! -d "$BUILD_80" ]; then
  echo "The Build path does not exist. Exiting..."
  exit 1
fi

# Check if percona-release is installed
echo "...Looking for percona-release installed on the machine"
if [[ ! -e `which percona-release` ]]; then
  echo "percona-release not found"
  echo "...Installing percona-release"
  if [ -f /usr/bin/yum ]; then
    sudo yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
  elif [ -f /usr/bin/apt ]; then
    wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
    sudo dpkg -i percona-release_latest.generic_all.deb
    sudo apt-get update
  fi
  echo "percona-release installed successfully at $(which percona-release)"
else
  echo "percona-release found at $(which percona-release)"
fi

# Check if xtrabackup 2.4 or 8.0 is installed
echo "...Looking for xtrabackup package installed on the machine"
if [[ ! -e `which xtrabackup` ]]; then
  echo "Xtrabackup not found"
  echo "...Installing percona-xtrabackup-24 package"
  sudo percona-release enable tools release
  if [ -f /usr/bin/yum ]; then
    sudo yum install -y percona-xtrabackup-24
  elif [ -f /usr/bin/apt ]; then
    sudo apt-get install -y percona-xtrabackup-24
  fi
  echo "Xtrabackup installed successfully at $(which xtrabackup)"
else
  echo "Xtrabackup found at $(which xtrabackup)"
  xtrabackup --version
fi

# Check if sysbench is installed
echo "...Looking for sysbench installed on the machine"
if [[ ! -e `which sysbench` ]]; then
  echo "Sysbench not found"
  echo "...Installing sysbench"
  if [ -f /usr/bin/yum ]; then
    sudo yum install -y sysbench
  elif [ -f /usr/bin/apt ]; then
    sudo apt-get install -y sysbench
  fi
  echo "Sysbench installed successfully at $(which sysbench)"
else
  echo "Sysbench found at $(which sysbench)"
fi

echo "Basedir 57 has been set to: $BUILD_57";
echo "Basedir 80 has been set to: $BUILD_80";

echo "Killing old mysqld instances"
pkill -9 mysqld 2>/dev/null

if [ -d $BUILD_57/pxc_node_57_1 ]; then
  echo "...Found existing PXC nodes."
  rm -rf $BUILD_57/pxc_node_57_1
  echo "Removed"
fi

if [ -d $BUILD_57/pxc_node_57_2 ]; then
  echo "...Found existing PXC nodes."
  rm -rf $BUILD_57/pxc_node_57_2
  echo "Removed"
fi

if [ -d $BUILD_80/pxc_node_80_1 ]; then
  echo "...Found existing PXC nodes."
  rm -rf $BUILD_80/pxc_node_80_1
  echo "Removed"
fi

if [ -d $BUILD_80/pxc_node_80_2 ]; then
  echo "...Found existing PXC nodes."
  rm -rf $BUILD_80/pxc_node_80_2
  echo "Removed"
fi

for X in $(seq 1 4); do
  echo "...Creating work directory for $X"
  if [ $X -eq 1 ]; then
    WORKDIR_57_1=$BUILD_57/pxc_node_57_1
    mkdir $WORKDIR_57_1
    mkdir $WORKDIR_57_1/cert
    echo "Workdir has been set to: $WORKDIR_57_1"
    SOCKET_57_1=$WORKDIR_57_1/dn_57_1/mysqld_57_1.sock
    ERR_FILE_57_1=$WORKDIR_57_1/node_57_1.err
  elif [ $X -eq 2 ]; then
    WORKDIR_57_2=$BUILD_57/pxc_node_57_2
    mkdir $WORKDIR_57_2
    mkdir $WORKDIR_57_2/cert
    echo "Workdir has been set to: $WORKDIR_57_2" 
    SOCKET_57_2=$WORKDIR_57_2/dn_57_2/mysqld_57_2.sock
    ERR_FILE_57_2=$WORKDIR_57_2/node_57_2.err
  elif [ $X -eq 3 ]; then
    WORKDIR_80_1=$BUILD_80/pxc_node_80_1
    mkdir $WORKDIR_80_1
    mkdir $WORKDIR_80_1/cert
    echo "Workdir has been set to: $WORKDIR_80_1"
    SOCKET_80_1=$WORKDIR_80_1/dn_80_1/mysqld_80_1.sock
    ERR_FILE_80_1=$WORKDIR_80_1/node_80_1.err
  else
    WORKDIR_80_2=$BUILD_80/pxc_node_80_2
    mkdir $WORKDIR_80_2
    mkdir $WORKDIR_80_2/cert
    echo "Workdir has been set to: $WORKDIR_80_2"
    SOCKET_80_2=$WORKDIR_80_2/dn_80_2/mysqld_80_2.sock
    ERR_FILE_80_2=$WORKDIR_80_2/node_80_2.err
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

for X in $(seq 1 2); do
  if [ $X -eq 1 ]; then
    BUILD_VALUE=$BUILD_57
    WORKDIR_VALUE=$WORKDIR_57_1
    SOCKET_VALUE=$SOCKET_57_1
    DATADIR_VALUE=dn_57_1
    NODE_VALUE=node_57_1.err
  else
    BUILD_VALUE=$BUILD_80
    WORKDIR_VALUE=$WORKDIR_80_1
    SOCKET_VALUE=$SOCKET_80_1
    DATADIR_VALUE=dn_80_1
    NODE_VALUE=node_80_1.err
  fi

echo "
[mysqld]

port = 4000
server-id=1
log-error-verbosity=3
core-file

# file paths
basedir=$BUILD_VALUE/
datadir=$WORKDIR_VALUE/$DATADIR_VALUE
log-error=$WORKDIR_VALUE/$NODE_VALUE
general_log=1
general_log_file=$WORKDIR_VALUE/$DATADIR_VALUE/general.log
slow_query_log=1
slow_query_log_file=$WORKDIR_VALUE/$DATADIR_VALUE/slow.log
socket=$SOCKET_VALUE
character-sets-dir=$BUILD_VALUE/share/charsets
lc-messages-dir=$BUILD_VALUE/share/

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
wsrep_provider=$BUILD_VALUE/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node4000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR_VALUE/cert/ca.pem
ssl-cert = $WORKDIR_VALUE/cert/server-cert.pem
ssl-key = $WORKDIR_VALUE/cert/server-key.pem
[client]
ssl-ca = $WORKDIR_VALUE/cert/ca.pem
ssl-cert = $WORKDIR_VALUE/cert/client-cert.pem
ssl-key = $WORKDIR_VALUE/cert/client-key.pem
[sst]
encrypt = 0
ssl-ca = $WORKDIR_VALUE/cert/ca.pem
ssl-cert = $WORKDIR_VALUE/cert/server-cert.pem
ssl-key = $WORKDIR_VALUE/cert/server-key.pem
wsrep_debug=1


" > $WORKDIR_VALUE/n1.cnf
done

for X in $(seq 1 2); do
  if [ $X -eq 1 ]; then
    BUILD_VALUE=$BUILD_57
    WORKDIR_VALUE=$WORKDIR_57_2
    SOCKET_VALUE=$SOCKET_57_2
    DATADIR_VALUE=dn_57_2
    NODE_VALUE=node_57_2.err
  else
    BUILD_VALUE=$BUILD_80
    WORKDIR_VALUE=$WORKDIR_80_2
    SOCKET_VALUE=$SOCKET_80_2
    DATADIR_VALUE=dn_80_2
    NODE_VALUE=node_80_2.err
  fi

echo "
[mysqld]

port = 5000
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BUILD_VALUE/
datadir=$WORKDIR_VALUE/$DATADIR_VALUE
log-error=$WORKDIR_VALUE/$NODE_VALUE
general_log=1
general_log_file=$WORKDIR_VALUE/$DATADIR_VALUE/general.log
slow_query_log=1
slow_query_log_file=$WORKDIR_VALUE/$DATADIR_VALUE/slow.log
socket=$SOCKET_VALUE
character-sets-dir=$BUILD_VALUE/share/charsets
lc-messages-dir=$BUILD_VALUE/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=OFF

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:4030'
wsrep_provider=$BUILD_VALUE/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:5020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node5000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR_VALUE/cert/ca.pem
ssl-cert = $WORKDIR_VALUE/cert/server-cert.pem
ssl-key = $WORKDIR_VALUE/cert/server-key.pem
[client]
ssl-ca = $WORKDIR_VALUE/cert/ca.pem
ssl-cert = $WORKDIR_VALUE/cert/client-cert.pem
ssl-key = $WORKDIR_VALUE/cert/client-key.pem
[sst]
encrypt = 0
ssl-ca = $WORKDIR_VALUE/cert/ca.pem
ssl-cert = $WORKDIR_VALUE/cert/server-cert.pem
ssl-key = $WORKDIR_VALUE/cert/server-key.pem
wsrep_debug=1

" > $WORKDIR_VALUE/n2.cnf
done

fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    SOCKET=$SOCKET_57_1
    ERR_FILE=$ERR_FILE_57_1
  elif [ $NR -eq 2 ]; then
    SOCKET=$SOCKET_57_2
    ERR_FILE=$ERR_FILE_57_2
  elif [ $NR -eq 3 ]; then
    SOCKET=$SOCKET_80_1
    ERR_FILE=$ERR_FILE_80_1
  elif [ $NR -eq 4 ]; then
    SOCKET=$SOCKET_80_2
    ERR_FILE=$ERR_FILE_80_2
  fi
}

pxc_startup_status(){
  NR=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if [ $NR -eq 1 ]; then
      if $BUILD_57/bin/mysqladmin -uroot -S$SOCKET_57_1 ping > /dev/null 2>&1; then
        echo "Node 57.$NR started successfully"
        break
      fi
    elif [ $NR -eq 2 ]; then
      if $BUILD_57/bin/mysqladmin -uroot -S$SOCKET_57_2 ping > /dev/null 2>&1; then
        echo "Node 57.$NR started successfully"
        break
      fi
    elif [ $NR -eq 3 ]; then
      if $BUILD_80/bin/mysqladmin -uroot -S$SOCKET_80_1 ping > /dev/null 2>&1; then
        echo "Node 80.1 upgraded and started successfully"
	break
      fi
    elif [ $NR -eq 4 ]; then
      if $BUILD_80/bin/mysqladmin -uroot -S$SOCKET_80_2 ping > /dev/null 2>&1; then
        echo "Node 80.2 upgraded and started successfully"
        break
      fi
    fi

    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
      if [ $NR -eq 1 ]; then
        echo "ERROR: Node 57.$NR failed to start. Check Error logs: $WORKDIR_57_1/node_57_1.err"
        exit 1
      elif [ $NR -eq 2 ]; then
        echo "ERROR: Node 57.$NR failed to start. Check Error logs: $WORKDIR_57_2/node_57_2.err"
        exit 1
      elif [ $NR -eq 3 ]; then
        echo "ERROR: Node 80.$NR failed to start. Check Error logs: $WORKDIR_80_1/node_80_1.err"
	exit 1
      elif [ $NR -eq 4 ]; then
        echo "ERROR: Node 80.$NR failed to start. Check Error logs: $WORKDIR_80_2/node_80_2.err"
	exit 1
      fi
    fi
  done
}

echo "...Creating data directories"
$BUILD_57/bin/mysqld --no-defaults --datadir=$BUILD_57/pxc_node_57_1/dn_57_1 --basedir=$BUILD_57 --initialize-insecure --log-error=$BUILD_57/pxc_node_57_1/node_57_1.err
echo "Data directory for PXC-5.7(1) created"

$BUILD_57/bin/mysqld --no-defaults --datadir=$BUILD_57/pxc_node_57_2/dn_57_2 --basedir=$BUILD_57 --initialize-insecure --log-error=$BUILD_57/pxc_node_57_2/node_57_2.err
echo "Data directory for PXC-5.7(2) created"

cp $WORKDIR_57_1/dn_57_1/*.pem $WORKDIR_57_1/cert/
cp $WORKDIR_57_2/dn_57_2/*.pem $WORKDIR_57_2/cert/

echo "...Starting PXC nodes"
fetch_err_socket 1
$BUILD_57/bin/mysqld --defaults-file=$BUILD_57/pxc_node_57_1/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
pxc_startup_status 1

fetch_err_socket 2
$BUILD_57/bin/mysqld --defaults-file=$BUILD_57/pxc_node_57_2/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

echo "...Checking 2 node PXC Cluster startup"
for X in $(seq 1 10); do
  sleep 1
  CLUSTER_UP=0;
  if $BUILD_57/bin/mysqladmin -uroot -S$SOCKET_57_1 ping > /dev/null 2>&1; then
    if [ `$BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `$BUILD_57/bin/mysql -uroot -S$SOCKET_57_2 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`$BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`$BUILD_57/bin/mysql -uroot -S$SOCKET_57_2 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
  fi
  # If count reached 4 (there are 4 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 4 ]; then
    echo "2 Node PXC 5.7 Cluster started ok. Clients:"
    echo "Node #1: `echo $BUILD_57/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_57_1"
    echo "Node #2: `echo $BUILD_57/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_57_2"
    break
  fi
  if [ $X -eq 10 ]; then
    echo "Server may have started, but the cluster does not seem to be in a consistent state"
    echo "Check Error logs for more info:"
    echo "$WORKDIR_57_1/node_57_1.err"
    echo "$WORKDIR_57_2/node_57_2.err"
  fi
done

echo "...Upgrading PXC 57(2) to 8.0"
echo "...Shutting down PXC 5.7(2) to restart with upgraded data directory"
$BUILD_57/bin/mysqladmin -uroot -h127.0.0.1 -P5000 shutdown > /dev/null 2>&1
sleep 20;
cp -R $WORKDIR_57_2/dn_57_2 $WORKDIR_80_2/dn_80_2

fetch_err_socket 4
$BUILD_80/bin/mysqld --defaults-file=$WORKDIR_80_2/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 4

echo "...Creating sysbench user"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -e"CREATE USER 'sysbench'@'localhost' IDENTIFIED BY 'test'"
echo "Successful"
echo "...Granting permissions to sysbench user"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -e"GRANT ALL ON *.* TO 'sysbench'@'localhost'"
echo "Successful"
echo "...Creating sbtest database"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -e"DROP DATABASE IF EXISTS sbtest"
$BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -e"CREATE DATABASE sbtest"
echo "Successful"

echo "...Preparing sysbench data on Node 1"
sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_57_1 --threads=$SYS_THREADS --tables=$SYS_TABLES --table-size=100 prepare > /dev/null 2>&1
echo "Data loaded successfully"
echo "...Running sysbench load on Node 1 for $SYS_DURATION seconds"
sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_57_1 --threads=$SYS_THREADS --tables=$SYS_TABLES --time=$SYS_DURATION --report-interval=1 --events=1870000000 --db-ps-mode=disable run > /dev/null 2>&1
echo "Sysbench run successful"

# Wait for the nodes sync
sleep 2;
echo "...Random verification of table counts"
for X in $(seq 1 10); do
  RAND=$[$RANDOM%50 + 1 ]
  # -N suppresses column names and -s is silent mode
  count_57_1=$($BUILD_57/bin/mysql -uroot -S$SOCKET_57_1 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  count_80_2=$($BUILD_80/bin/mysql -uroot -S$SOCKET_80_2 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  if [ $count_57_1 -eq $count_80_2 ]; then
   echo "Data replicated and matched successfully sbtest$RAND count: $count_57_1 = $count_80_2"
  else
   echo "ERROR: Data mismatch found. sbtest$RAND count: $count_57_2 = $count_80_2"
   exit 1
  fi
done

echo "...Upgrading PXC 57(1) to 8.0"
echo "...Shutting down PXC 5.7(1) to restart with upgraded data directory"
$BUILD_57/bin/mysqladmin -uroot -h127.0.0.1 -P4000 shutdown > /dev/null 2>&1
sleep 20;
cp -R $WORKDIR_57_1/dn_57_1 $WORKDIR_80_1/dn_80_1
#####################################################################################
# We cannot start PXC 8.0 cluster if we have wsrep_sst_auth=root: in the cnf file.  #
# However, same setting is required to start a PXC-5.7 cluster                      #
#####################################################################################
sed -i '/wsrep_sst_auth/d' $WORKDIR_80_1/n1.cnf

fetch_err_socket 3
$BUILD_80/bin/mysqld --defaults-file=$WORKDIR_80_1/n1.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 3

echo "...Running sysbench load on upgraded Node 1 for $SYS_DURATION seconds"
sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_80_1 --threads=$SYS_THREADS --tables=$SYS_TABLES --time=$SYS_DURATION --report-interval=1 --events=1870000000 --db-ps-mode=disable run > /dev/null 2>&1
echo "Sysbench run successful"

# Wait for the nodes sync
sleep 2;
echo "...Random verification of table counts"
for X in $(seq 1 10); do
  RAND=$[$RANDOM%50 + 1 ]
  # -N suppresses column names and -s is silent mode
  count_80_1=$($BUILD_80/bin/mysql -uroot -S$SOCKET_80_1 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  count_80_2=$($BUILD_80/bin/mysql -uroot -S$SOCKET_80_2 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
  if [ $count_80_1 -eq $count_80_2 ]; then
   echo "Data replicated and matched successfully sbtest$RAND count: $count_80_1 = $count_80_2"
  else
   echo "ERROR: Data mismatch found. sbtest$RAND count: $count_80_1 = $count_80_2"
   exit 1
  fi
done

echo "Killing running mysqld instances"
pkill -9 mysqld 2>/dev/null

echo "Done. Exiting $0 with exit code 0..."
exit 0
