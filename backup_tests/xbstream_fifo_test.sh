#!/bin/bash

# Internal Script variables
XTRABACKUP_DIR=$HOME/work/PXB-2514-8.0/bld_28_jun_2023/install
PS_DIR=$HOME/mysql-release-8.0
DATADIR=$PS_DIR/data_80
SOCKET=/tmp/mysql_22000.sock
BACKUP_DIR=/tmp/backup
PSTRESS_BIN=$HOME/pstress/src
ENCRYPTION=0; COMPRESS=0; ENCRYPT=""; DECRYPT=""; ENCRYPT_KEY=""

#FIFO variables
FIFO_STREAM=30
FIFO_DIR=/tmp/stream
BACKUP_NAME=full_backup

# Sysbench variables
tables=500
records=1000
threads=10
time=60

cleanup() {
  if [ ! -d $BACKUP_DIR ]; then
    mkdir $BACKUP_DIR
  else
    rm -rf $BACKUP_DIR/*
  fi
  if [ -d $FIFO_DIR ]; then
    if [ $(ls -lrt $FIFO_DIR | grep -v total | wc -l) -gt 0 ]; then
      rm $FIFO_DIR/*
    fi
  fi
  $XTRABACKUP_DIR/bin/xbcloud delete --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 full_backup > $LOGDIR/cleanup.log 2>&1
  $XTRABACKUP_DIR/bin/xbcloud delete --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 full >> $LOGDIR/cleanup.log 2>&1
  $XTRABACKUP_DIR/bin/xbcloud delete --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 inc1 >> $LOGDIR/cleanup.log 2>&1
  $XTRABACKUP_DIR/bin/xbcloud delete --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 inc2 >> $LOGDIR/cleanup.log 2>&1
  $XTRABACKUP_DIR/bin/xbcloud delete --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 inc3 >> $LOGDIR/cleanup.log 2>&1
}

xbcloud_put() {
 BACKUP_NAME=$1
 echo "$XTRABACKUP_DIR/bin/xbcloud put --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR $BACKUP_NAME"
 $XTRABACKUP_DIR/bin/xbcloud put --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR $BACKUP_NAME > $LOGDIR/upload.log 2>&1
}

xbcloud_get() {
  BACKUP_NAME=$1
  $XTRABACKUP_DIR/bin/xbcloud get --storage=s3 --s3-access-key=admin --s3-secret-key=password --s3-endpoint=http://localhost:9000 --s3-bucket=my-bucket --parallel=64 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR $BACKUP_NAME > $LOGDIR/download.log 2>&1
}

stop_server() {
  $PS_DIR/bin/mysqladmin -uroot -S$SOCKET shutdown
}

init_datadir() {
  if [ -d $DATADIR ]; then
    rm -rf $DATADIR
  fi
  echo "=>Creating mysql data directory"
  $PS_DIR/bin/mysqld --no-defaults --datadir=$DATADIR --initialize-insecure > $PS_DIR/error.log 2>&1
  echo "..Data directory created"
}

start_server() {
  # This function starts the server
  echo "=>Starting MySQL server"
  if [ $ENCRYPTION -eq 0 ]; then
    $PS_DIR/bin/mysqld --no-defaults --datadir=$DATADIR --port=22000 --socket=$SOCKET --max-connections=1024 --log-error=$PS_DIR/error.log --general-log --log-error-verbosity=3 --core-file > $PS_DIR/error.log 2>&1 &
  else
    $PS_DIR/bin/mysqld --no-defaults --datadir=$DATADIR --port=22000 --socket=$SOCKET --plugin-dir=$PS_DIR/lib/plugin --early-plugin-load=keyring_file.so --keyring_file_data=$PS_DIR/mykey --max-connections=1024 --log-error=$PS_DIR/error.log --general-log --log-error-verbosity=3 --core-file > $PS_DIR/error.log 2>&1 &
  fi

  for X in $(seq 0 90); do
    sleep 1
    if $PS_DIR/bin/mysqladmin -uroot -S$SOCKET ping > /dev/null 2>&1; then
      echo "..Server started successfully"
      break
    fi
    if [ $X -eq 90 ]; then
      echo "ERR: Database could not be started. Please check error logs: $PS_DIR/error.log"
      exit 1
    fi
  done
}

sysbench_create_load() {
  # Create user
  $PS_DIR/bin/mysql -A -uroot -S $SOCKET -e "CREATE USER sysbench@'%' IDENTIFIED WITH mysql_native_password BY 'test';"
  $PS_DIR/bin/mysql -A -uroot -S $SOCKET -e "GRANT ALL ON *.* TO sysbench@'%';"
  $PS_DIR/bin/mysql -A -uroot -S $SOCKET -e "DROP DATABASE IF EXISTS sbtest;CREATE DATABASE sbtest;"

  sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET --threads=$threads --tables=$tables --table-size=$records prepare > $LOGDIR/sysbench.log
}

sysbench_run_load() {
  # Run load
  sysbench /usr/share/sysbench/oltp_read_write.lua --mysql-db=sbtest --mysql-user=sysbench --mysql-password=test --db-driver=mysql --mysql-socket=$SOCKET --threads=$threads --tables=$tables --time=$time --report-interval=1 --events=1870000000 --db-ps-mode=disable run > $LOGDIR/sysbench_run.log 2>&1 &
}

pstress_run_load() {
  $PS_DIR/bin/mysql -A -uroot -S $SOCKET -e "DROP DATABASE IF EXISTS test; CREATE DATABASE test"
  if [ $ENCRYPTION -eq 0 ]; then
    $PSTRESS_BIN/pstress-ps --tables 150 --records 1000 --seconds 120 --threads 10 --logdir $PSTRESS_BIN/log --socket $SOCKET --no-encryption --only-partition-tables > $LOGDIR/pstress.log 2>&1 &
  else
    $PSTRESS_BIN/pstress-ps --tables 500 --records 1000 --seconds 120 --threads 10 --logdir $PSTRESS_BIN/log --socket $SOCKET > $LOGDIR/pstress.log 2>&1 &
  fi
}


full_backup_and_restore() {
echo "=>Taking Backup"
$XTRABACKUP_DIR/bin/xtrabackup --user=root --password='' --datadir=$DATADIR -S $SOCKET --backup $ENCRYPT $ENCRYPT_KEY --parallel=64 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --core-file > $LOGDIR/backup.log 2>&1 &

xbcloud_put full_backup
if [ $(cat $LOGDIR/upload.log | grep "Upload failed" | wc -l) -eq 1 ]; then
  echo "..Upload Failed"
  exit 1
else
  echo "..Backup successful"
fi

echo "=>Restoring Backup"
$XTRABACKUP_DIR/bin/xbstream -x -C $BACKUP_DIR --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --parallel=64 &
xbcloud_get full_backup

if [ $(cat $LOGDIR/download.log | grep "Download failed" | wc -l) -eq 1 ]; then
  echo "..Download Failed"
  exit 1
else
  echo "..Restore successful"
fi

if [ $COMPRESS -eq 1 ]; then
  echo "=>Decompress Backup"
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --decompress --target_dir=$BACKUP_DIR --core-file > $LOGDIR/decompress.log 2>&1
  echo "..Decompress Successful"
  COMPRESS=0
fi

if [ "$ENCRYPT" != "" ]; then
  echo "=>Decrypting the Backup"
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults $DECRYPT $ENCRYPT_KEY --target_dir=$BACKUP_DIR --core-file > $LOGDIR/decompress.log 2>&1
  ENCRYPT=""
  echo "..Decrypting successful"
fi

echo "=>Preparing Backup"
if [ $ENCRYPTION -eq 0 ]; then
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --target_dir=$BACKUP_DIR --core-file > $LOGDIR/prepare.log 2>&1
else
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --target_dir=$BACKUP_DIR --keyring_file_data=$PS_DIR/mykey --core-file > $LOGDIR/prepare.log 2>&1
fi
echo "..Prepare successful"
}

incremental_backup_and_restore() {
echo "=>Taking Full Backup"
if [ ! -d $HOME/lsn/full ]; then
  mkdir -p $HOME/lsn/full
else
  rm -rf $HOME/lsn/full
  mkdir -p $HOME/lsn/full
fi
$XTRABACKUP_DIR/bin/xtrabackup --backup --user=root -S $SOCKET --datadir=$DATADIR --extra-lsndir=$HOME/lsn/full --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --core-file >> $LOGDIR/backup_inc.log 2>&1 &

xbcloud_put full
echo "..Full Backup successful"

sleep 5;
echo "=>Taking Incremental Backup 1"
if [ ! -d $HOME/lsn/inc1 ]; then
  mkdir -p $HOME/lsn/inc1
else
  rm -rf $HOME/lsn/inc1
  mkdir -p $HOME/lsn/inc1
fi
$XTRABACKUP_DIR/bin/xtrabackup --backup --user=root -S $SOCKET --datadir=$DATADIR --extra-lsndir=$HOME/lsn/inc1 --incremental-basedir=$HOME/lsn/full --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --core-file > $LOGDIR/inc1.log 2>&1 &

xbcloud_put inc1
echo "..Successful"

sleep 5
echo "=>Taking Incremental Backup 2"
if [ ! -d $HOME/lsn/inc2 ]; then
  mkdir -p $HOME/lsn/inc2
else
  rm -rf $HOME/lsn/inc2
  mkdir -p $HOME/lsn/inc2
fi
$XTRABACKUP_DIR/bin/xtrabackup --backup --user=root -S $SOCKET --datadir=$DATADIR --extra-lsndir=$HOME/lsn/inc2 --incremental-basedir=$HOME/lsn/inc1 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --core-file > $LOGDIR/inc2.log 2>&1 &

xbcloud_put inc2
echo "..Successful"

sleep 5
echo "=>Taking Incremental Backup 3"
if [ ! -d $HOME/lsn/inc3 ]; then
  mkdir -p $HOME/lsn/inc3
else
  rm -rf $HOME/lsn/inc3
  mkdir -p $HOME/lsn/inc3
fi
$XTRABACKUP_DIR/bin/xtrabackup --backup --user=root -S $SOCKET --datadir=$DATADIR --extra-lsndir=$HOME/lsn/inc3 --incremental-basedir=$HOME/lsn/inc2 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --core-file > $LOGDIR/inc3.log 2>&1 &

xbcloud_put inc3
echo "..Successful"

echo "=>Restoring Backup..."
rm -rf $BACKUP_DIR/full/
mkdir $BACKUP_DIR/full
$XTRABACKUP_DIR/bin/xbstream -x -C $BACKUP_DIR/full --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --parallel=64 &
xbcloud_get full

rm -rf $BACKUP_DIR/inc1/
mkdir $BACKUP_DIR/inc1
$XTRABACKUP_DIR/bin/xbstream -x -C $BACKUP_DIR/inc1 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --parallel=64 &
xbcloud_get inc1

rm -rf $BACKUP_DIR/inc2/
mkdir $BACKUP_DIR/inc2
$XTRABACKUP_DIR/bin/xbstream -x -C $BACKUP_DIR/inc2 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --parallel=64 &
xbcloud_get inc2

rm -rf $BACKUP_DIR/inc3/
mkdir $BACKUP_DIR/inc3
$XTRABACKUP_DIR/bin/xbstream -x -C $BACKUP_DIR/inc3 --fifo-streams=$FIFO_STREAM --fifo-dir=$FIFO_DIR --parallel=64 &
xbcloud_get inc3

echo "=>Preparing Full Backup"
if [ $ENCRYPTION -eq 0 ]; then
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=$BACKUP_DIR/full --core-file > $LOGDIR/prepare_full.log 2>&1
else
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=$BACKUP_DIR/full --keyring_file_data=$PS_DIR/mykey --core-file > $LOGDIR/prepare_full.log 2>&1
echo "..Prepare successful"
fi

echo "=>Preparing Incremental Backup 1"
if [ $ENCRYPTION -eq 0 ]; then
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --apply-log-only --target-dir=$BACKUP_DIR/full --incremental-dir=$BACKUP_DIR/inc1 --core-file > $LOGDIR/prepare_inc1.log 2>&1
else
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --apply-log-only --target-dir=$BACKUP_DIR/full --keyring_file_data=$PS_DIR/mykey --incremental-dir=$BACKUP_DIR/inc1 --core-file > $LOGDIR/prepare_inc1.log 2>&1
fi
echo "..Successful"

echo "=>Preparing Incremental Backup 2"
if [ $ENCRYPTION -eq 0 ]; then
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --apply-log-only --target-dir=$BACKUP_DIR/full --incremental-dir=$BACKUP_DIR/inc2 --core-file > $LOGDIR/prepare_inc2.log 2>&1
else
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --apply-log-only --target-dir=$BACKUP_DIR/full --keyring_file_data=$PS_DIR/mykey --incremental-dir=$BACKUP_DIR/inc2 --core-file > $LOGDIR/prepare_inc2.log 2>&1
fi
echo "..Successful"

echo "=>Preparing Incremental Backup 3"
if [ $ENCRYPTION -eq 0 ]; then
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --target-dir=$BACKUP_DIR/full --incremental-dir=$BACKUP_DIR/inc3 --core-file > $LOGDIR/prepare_inc3.log 2>&1
else
  $XTRABACKUP_DIR/bin/xtrabackup --no-defaults --prepare --target-dir=$BACKUP_DIR/full --keyring_file_data=$PS_DIR/mykey --incremental-dir=$BACKUP_DIR/inc3 --core-file > $LOGDIR/prepare_inc3.log 2>&1
fi
echo "..Successful"
}

#Actual test begins here..
echo "###################################################"
echo "# 1. Test FIFO xbstream: Full Backup and Restore  #"
echo "###################################################"

LOGDIR=$HOME/1
if [ -d $LOGDIR ]; then
  rm -rf $LOGDIR/*
else
  mkdir $LOGDIR
fi
echo "=>Cleanup in progress"
cleanup
echo "..Cleanup completed"

sudo pkill -9 mysqld
init_datadir
start_server

echo "=>Create load using sysbench"
sysbench_create_load
echo ".. Sysbench load created"

echo "=>Run Sysbench Load (Read/Write)"
sysbench_run_load

full_backup_and_restore
echo "=>Shutting down MySQL server"
stop_server
echo "..Successful"

echo "=>Taking backup of original datadir"
if [ ! -d ${DATADIR}_bk ]; then
  mv $DATADIR ${DATADIR}_bk
else
  rm -rf ${DATADIR}_bk
  mv $DATADIR ${DATADIR}_bk
fi
echo "..Successful"

echo "Copy the backup in datadir"
$XTRABACKUP_DIR/bin/xtrabackup --no-defaults --copy-back --target_dir=$BACKUP_DIR --datadir=$DATADIR --core-file > $LOGDIR/copy_back1.log 2>&1
start_server

echo "#######################################################"
echo "# 2. Test FIFO xbstream: Incremental Backup           #"
echo "#######################################################"

LOGDIR=$HOME/2
if [ -d $LOGDIR ]; then
  rm -rf $LOGDIR/*
else
  mkdir $LOGDIR
fi
echo "=>Cleanup in progress"
cleanup
echo "..Cleanup completed"

echo "=>Run Sysbench Load (Read/Write)"
time=60
sysbench_run_load

incremental_backup_and_restore
echo "=>Shutting down MySQL server"
stop_server
echo "..Successful"

echo "=>Taking backup of original datadir"
if [ ! -d ${DATADIR}_bk2 ]; then
  mv $DATADIR ${DATADIR}_bk2
else
  rm -rf ${DATADIR}_bk2
  mv $DATADIR ${DATADIR}_bk2
fi
echo "..Successful"

echo "Copy the backup in datadir"
$XTRABACKUP_DIR/bin/xtrabackup --no-defaults --copy-back --target_dir=$BACKUP_DIR/full --datadir=$DATADIR --core-file > $LOGDIR/copy_back2.log 2>&1
start_server

echo "#######################################################"
echo "# 3. Test FIFO xbstream: Compressed Backup            #"
echo "#######################################################"

LOGDIR=$HOME/3
if [ -d $LOGDIR ]; then
  rm -rf $LOGDIR/*
else
  mkdir $LOGDIR
fi
echo "=>Cleanup in progress"
cleanup
echo "..Cleanup completed"

COMPRESS_OPTIONS="--compress=zstd --compress-zstd-level=19 --compress-threads=10"
COMPRESS=1
sysbench_run_load
full_backup_and_restore
echo "=>Shutting down MySQL server"
stop_server
echo "..Successful"

echo "=>Taking backup of original datadir"
if [ ! -d ${DATADIR}_bk3 ]; then
  mv $DATADIR ${DATADIR}_bk3
else
  rm -rf ${DATADIR}_bk3
  mv $DATADIR ${DATADIR}_bk3
fi
echo "..Successful"

echo "Copy the backup in datadir"
$XTRABACKUP_DIR/bin/xtrabackup --no-defaults --copy-back --target_dir=$BACKUP_DIR --datadir=$DATADIR --core-file > $LOGDIR/copy_back3.log 2>&1
start_server

echo "#######################################################"
echo "# 4. Test FIFO xbstream: Test with partition tables   #"
echo "#######################################################"

LOGDIR=$HOME/4
if [ -d $LOGDIR ]; then
  rm -rf $LOGDIR/*
else
  mkdir $LOGDIR
fi
echo "=>Cleanup in progress"
cleanup
echo "..Cleanup completed"

echo "=>Run pstress load"
pstress_run_load

incremental_backup_and_restore
echo "=>Shutting down MySQL server"
stop_server
echo "..Successful"

echo "=>Taking backup of original datadir"
if [ ! -d ${DATADIR}_bk4 ]; then
  mv $DATADIR ${DATADIR}_bk4
else
  rm -rf ${DATADIR}_bk4
  mv $DATADIR ${DATADIR}_bk4
fi
echo "..Successful"

echo "Copy the backup in datadir"
$XTRABACKUP_DIR/bin/xtrabackup --no-defaults --copy-back --target_dir=$BACKUP_DIR/full --datadir=$DATADIR --core-file > $LOGDIR/copy_back4.log 2>&1
start_server

echo "#######################################################"
echo "# 5. Test FIFO xbstream: Test with encrypted tables   #"
echo "#######################################################"

LOGDIR=$HOME/5
if [ -d $LOGDIR ]; then
  rm -rf $LOGDIR/*
else
  mkdir $LOGDIR
fi
echo "=>Cleanup in progress"
cleanup
echo "..Cleanup completed"

ENCRYPTION=1
stop_server
rm -rf $DATADIR
init_datadir
start_server
echo "=>Run pstress load"
pstress_run_load

incremental_backup_and_restore
echo "=>Shutting down MySQL server"
stop_server
echo "..Successful"

echo "=>Taking backup of original datadir"
if [ ! -d ${DATADIR}_bk5 ]; then
  mv $DATADIR ${DATADIR}_bk5
else
  rm -rf ${DATADIR}_bk5
  mv $DATADIR ${DATADIR}_bk5
fi
echo "..Successful"

echo "Copy the backup in datadir"
$XTRABACKUP_DIR/bin/xtrabackup --no-defaults --copy-back --target_dir=$BACKUP_DIR/full --datadir=$DATADIR --core-file > $LOGDIR/copy_back5.log 2>&1
start_server

echo "#######################################################"
echo "# 6. Test FIFO xbstream: Test with encrypted backup   #"
echo "#######################################################"
ENCRYPT="--encrypt=AES256"
ENCRYPT_KEY="--encrypt-key=maaoWib1SuXz0UKexOZW37bUbtfEMOdA"
ENCRYPT_KEY_FILE="--encrypt-key-file=/home/mohit.joshi/keyfile"
DECRYPT="--decrypt=AES256"

LOGDIR=$HOME/6
if [ -d $LOGDIR ]; then
  rm -rf $LOGDIR/*
else
  mkdir $LOGDIR
fi
echo "=>Cleanup in progress"
cleanup
echo "..Cleanup completed"

stop_server
ENCRYPTION=1
start_server

echo "=>Run pstress load"
pstress_run_load
sleep 60
full_backup_and_restore

echo "=>Shutting down MySQL server"
stop_server
echo "..Successful"

echo "=>Taking backup of original datadir"
if [ ! -d ${DATADIR}_bk6 ]; then
  mv $DATADIR ${DATADIR}_bk6
else
  rm -rf ${DATADIR}_bk6
  mv $DATADIR ${DATADIR}_bk6
fi
echo "..Successful"

echo "Copy the backup in datadir"
$XTRABACKUP_DIR/bin/xtrabackup --no-defaults --copy-back --target_dir=$BACKUP_DIR --datadir=$DATADIR --core-file > $LOGDIR/copy_back6.log 2>&1
start_server
