#!/bin/bash

###############################################################################################
#                                                                                             #
# Author  :  Mohit Joshi                                                                      #
# Script  :  setup_ps_group_replication.sh                                                    #
# Created :  07-July-2022                                                                     #
# Purpose :  The script starts a 3 node Group Replication setup on PS tarball                 #
#            and run some load using sysbench and verify data is replicated successfully      #
#                                                                                             #
# Usage   :  ./setup_ps_group_replication.sh /path/PS-8.0/extracted/tarball                   #
#                                                                                             #
# Note    : By default, the script starts a 3 node GR and leaves the running server as is.    #
#           To run sysbench testing, disable this flag by setting ONLY_GR_SETUP=0             #
#                                                                                             #
###############################################################################################

BUILD_DIR=$(realpath $1)
UUID=$(uuidgen)
ONLY_GR_SETUP=1

# Check if Build paths are valid
if [ ! -d $BUILD_DIR ]; then
  echo "ERROR: The Build path does not exist. Exiting..."
  exit 1
fi

echo "Killing any previous running mysqld server"
pkill -9 mysqld

WORKDIR=$BUILD_DIR/gr_setup
if [ -d $WORKDIR ]; then
  rm -rf $WORKDIR
fi

mkdir $WORKDIR

# Create datadir
echo "...Creating datadir 1"
$BUILD_DIR/bin/mysqld --no-defaults --datadir=$WORKDIR/data_1 --initialize-insecure > /dev/null 2>&1
echo "Created datadir 1"
echo "...Creating datadir 2"
$BUILD_DIR/bin/mysqld --no-defaults --datadir=$WORKDIR/data_2 --initialize-insecure > /dev/null 2>&1
echo "Created datadir 2"
echo "...Creating datadir 3"
$BUILD_DIR/bin/mysqld --no-defaults --datadir=$WORKDIR/data_3 --initialize-insecure > /dev/null 2>&1
echo "Created datadir 3"

DATADIR_1=$WORKDIR/data_1
DATADIR_2=$WORKDIR/data_2
DATADIR_3=$WORKDIR/data_3

echo "
[mysqld]

# General replication settings
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
gtid_mode = ON
enforce_gtid_consistency = ON
master_info_repository = TABLE
relay_log_info_repository = TABLE
binlog_checksum = NONE
log_slave_updates = ON
log_bin = binlog
binlog_format = ROW
transaction_write_set_extraction = XXHASH64
loose-group_replication_bootstrap_group = OFF
loose-group_replication_start_on_boot = OFF
loose-group_replication_ssl_mode = REQUIRED
loose-group_replication_recovery_use_ssl = 1

# Shared replication group configuration
loose-group_replication_group_name = "$UUID"
loose-group_replication_ip_whitelist = "127.0.0.1,127.0.0.1,127.0.0.1"
loose-group_replication_group_seeds = "127.0.0.1:22100,127.0.0.1:22102,127.0.0.1:22104"

# Single or Multi-primary mode? Uncomment these two lines
# for multi-primary mode, where any host can accept writes
#loose-group_replication_single_primary_mode = OFF
#loose-group_replication_enforce_update_everywhere_checks = ON

# Host specific replication configuration
server_id = 1
bind-address = "127.0.0.1"
report_host = "127.0.0.1"
loose-group_replication_local_address = "127.0.0.1:22100"
" > $DATADIR_1/n1.cnf

echo "
[mysqld]

# General replication settings
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
gtid_mode = ON
enforce_gtid_consistency = ON
master_info_repository = TABLE
relay_log_info_repository = TABLE
binlog_checksum = NONE
log_slave_updates = ON
log_bin = binlog
binlog_format = ROW
transaction_write_set_extraction = XXHASH64
loose-group_replication_bootstrap_group = OFF
loose-group_replication_start_on_boot = OFF
loose-group_replication_ssl_mode = REQUIRED
loose-group_replication_recovery_use_ssl = 1

# Shared replication group configuration
loose-group_replication_group_name = "$UUID"
loose-group_replication_ip_whitelist = "127.0.0.1,127.0.0.1,127.0.0.1"
loose-group_replication_group_seeds = "127.0.0.1:22100,127.0.0.1:22102,127.0.0.1:22104"

# Single or Multi-primary mode? Uncomment these two lines
# for multi-primary mode, where any host can accept writes
#loose-group_replication_single_primary_mode = OFF
#loose-group_replication_enforce_update_everywhere_checks = ON

# Host specific replication configuration
server_id = 2
bind-address = "127.0.0.1"
report_host = "127.0.0.1"
loose-group_replication_local_address = "127.0.0.1:22102"
" > $DATADIR_2/n2.cnf

echo "
[mysqld]

# General replication settings
disabled_storage_engines="MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
gtid_mode = ON
enforce_gtid_consistency = ON
master_info_repository = TABLE
relay_log_info_repository = TABLE
binlog_checksum = NONE
log_slave_updates = ON
log_bin = binlog
binlog_format = ROW
transaction_write_set_extraction = XXHASH64
loose-group_replication_bootstrap_group = OFF
loose-group_replication_start_on_boot = OFF
loose-group_replication_ssl_mode = REQUIRED
loose-group_replication_recovery_use_ssl = 1

# Shared replication group configuration
loose-group_replication_group_name = "$UUID"
loose-group_replication_ip_whitelist = "127.0.0.1,127.0.0.1,127.0.0.1"
loose-group_replication_group_seeds = "127.0.0.1:22100,127.0.0.1:22102,127.0.0.1:22104"

# Single or Multi-primary mode? Uncomment these two lines
# for multi-primary mode, where any host can accept writes
#loose-group_replication_single_primary_mode = OFF
#loose-group_replication_enforce_update_everywhere_checks = ON

# Host specific replication configuration
server_id = 3
bind-address = "127.0.0.1"
report_host = "127.0.0.1"
loose-group_replication_local_address = "127.0.0.1:22104"
" > $DATADIR_3/n3.cnf

PORT_1=22000
PORT_2=22002
PORT_3=22004
SOCKET_1=/tmp/mysql_22000.sock
SOCKET_2=/tmp/mysql_22002.sock
SOCKET_3=/tmp/mysql_22004.sock

# Start server nodes
$BUILD_DIR/bin/mysqld --defaults-file=$DATADIR_1/n1.cnf --datadir=$DATADIR_1 --port=$PORT_1 --socket=$SOCKET_1 --plugin-dir=$BUILD_DIR/lib/plugin --early-plugin-load=keyring_file.so --keyring_file_data=$DATADIR_1/mykey --max-connections=1024 --log-error --general-log --log-error-verbosity=3 --core-file &

sleep 3;

$BUILD_DIR/bin/mysqld --defaults-file=$DATADIR_2/n2.cnf --datadir=$DATADIR_2 --port=$PORT_2 --socket=$SOCKET_2 --plugin-dir=$BUILD_DIR/lib/plugin --early-plugin-load=keyring_file.so --keyring_file_data=$DATADIR_2/mykey --max-connections=1024 --log-error --general-log --log-error-verbosity=3 --core-file &

sleep 3;

$BUILD_DIR/bin/mysqld --defaults-file=$DATADIR_3/n3.cnf --datadir=$DATADIR_3 --port=$PORT_3 --socket=$SOCKET_3 --plugin-dir=$BUILD_DIR/lib/plugin --early-plugin-load=keyring_file.so --keyring_file_data=$DATADIR_3/mykey --max-connections=1024 --log-error --general-log --log-error-verbosity=3 --core-file &

sleep 3;

echo "
SET SQL_LOG_BIN=0;
CREATE USER 'repl'@'%' IDENTIFIED BY 'password' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
SET SQL_LOG_BIN=1;
CHANGE REPLICATION SOURCE TO SOURCE_USER='repl', SOURCE_PASSWORD='password' FOR CHANNEL 'group_replication_recovery';
INSTALL PLUGIN group_replication SONAME 'group_replication.so';
" > $WORKDIR/gr_setup.sql

$BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -Ns -e"source $WORKDIR/gr_setup.sql"
sleep 2;
$BUILD_DIR/bin/mysql -uroot -S$SOCKET_2 -Ns -e"source $WORKDIR/gr_setup.sql"
sleep 2;
$BUILD_DIR/bin/mysql -uroot -S$SOCKET_3 -Ns -e"source $WORKDIR/gr_setup.sql"
sleep 2;

$BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -Ns -e"SET GLOBAL group_replication_bootstrap_group=ON;"
$BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -Ns -e"START GROUP_REPLICATION;"
$BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -Ns -e"SET GLOBAL group_replication_bootstrap_group=OFF;"


$BUILD_DIR/bin/mysql -uroot -S$SOCKET_2 -Ns -e"START GROUP_REPLICATION;"
sleep 2;
$BUILD_DIR/bin/mysql -uroot -S$SOCKET_3 -Ns -e"START GROUP_REPLICATION;"
sleep 2;

echo "Group replication started successfully"
echo "Clients: $BUILD_DIR/bin/mysql -uroot -S$SOCKET_1"
echo "Clients: $BUILD_DIR/bin/mysql -uroot -S$SOCKET_2"
echo "Clients: $BUILD_DIR/bin/mysql -uroot -S$SOCKET_3"

if [ $ONLY_GR_SETUP -eq 0 ]; then
  echo "...Creating sysbench user"
  $BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -e"CREATE USER 'sysbench'@'localhost' IDENTIFIED BY 'test'"
  echo "Successful"
  echo "...Granting permissions to sysbench user"
  $BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -e"GRANT ALL ON *.* TO 'sysbench'@'localhost'"
  echo "Successful"
  echo "...Creating sbtest database"
  $BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -e"DROP DATABASE IF EXISTS sbtest"
  $BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -e"CREATE DATABASE sbtest"
  echo "Successful"

  echo "...Preparing sysbench data on Node 1"
  sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_1 --threads=5 --tables=50 --table-size=100 prepare > /dev/null 2>&1
  echo "Data loaded successfully"
  echo "...Running sysbench load on Node 1 for 60 seconds"
  sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET_1 --threads=5 --tables=50 --time=60 --report-interval=1 --events=1870000000 --db-ps-mode=disable run > /dev/null 2>&1
  echo "Sysbench run successful"


# Wait for the nodes sync
  sleep 5;
  echo "...Random verification of table counts"
  for X in $(seq 1 10); do
    RAND=$[$RANDOM%50 + 1 ]
    # -N suppresses column names and -s is silent mode
    count_1=$($BUILD_DIR/bin/mysql -uroot -S$SOCKET_1 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
    count_2=$($BUILD_DIR/bin/mysql -uroot -S$SOCKET_2 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
    count_3=$($BUILD_DIR/bin/mysql -uroot -S$SOCKET_3 -Ns -e"SELECT count(*) FROM sbtest.sbtest$RAND")
    if [ $count_1 -eq $count_2 ] && [ $count_2  -eq $count_3 ]; then
      echo "Data replicated and matched successfully sbtest$RAND count: $count_1 = $count_2 = $count_3"
    else
      echo "ERROR: Data mismatch found. sbtest$RAND count: $count_1 : $count_2 : $count_3"
      exit 1
    fi
  done
fi
