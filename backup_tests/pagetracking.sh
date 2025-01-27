#!/bin/bash

#############################################################################
# Created By Manish Chawla, Percona LLC                                     #
# Modified By Mohit Joshi, Percona LLC
# This script tests backup with a load tool as pquery/pstress/sysbench      #
# Assumption: PS and PXB are already installed as tarballs                  #
# Usage:                                                                    #
# 1. Compile pquery/pstress with mysql                                      #
# 2. Set variables in this script:                                          #
#    xtrabackup_dir, mysqldir, datadir, backup_dir, qascripts, logdir,      #
#    load_tool, tool_dir, num_tables, table_size, kmip, kms configuration   #
# 3. For usage run the script as: ./inc_backup_load_tests.sh                #
# 4. Logs are available in: logdir                                          #
#############################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb-8.0/bld_8.0.35_r/install/bin"
export mysqldir="$HOME/mysql-8.0/bld_8.0.37/install"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"
export mysql_start_timeout=60

# Set tool variables
load_tool="pstress" # Set value as pquery/pstress/sysbench
num_tables=10 # Used for Sysbench
table_size=1000 # Used for Sysbench
tool_dir="$HOME/pstress/src" # Pquery/pstress dir

if ${mysqldir}/bin/mysqld --version | grep "MySQL Community Server" > /dev/null 2>&1 ; then
  MS=1
else
  MS=0
fi

initialize_db() {
  # This function initializes and starts mysql database
  if [ ! -d "${logdir}" ]; then
    mkdir "${logdir}"
  fi

  echo "=>Creating data directory"
  $mysqldir/bin/mysqld --no-defaults --datadir=$datadir --initialize-insecure > $mysqldir/mysql_install_db.log 2>&1
  echo "..Data directory created"

  start_server
  $mysqldir/bin/mysql -uroot -S$mysqldir/socket.sock -e "DROP DATABASE IF EXISTS test"
  $mysqldir/bin/mysql -uroot -S$mysqldir/socket.sock -e "CREATE DATABASE IF NOT EXISTS test"

  # Create data using sysbench
  if [[ "${load_tool}" = "sysbench" ]]; then
    if [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
      sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock prepare >"${logdir}"/sysbench.log
    else
      # Encryption enabled
      for ((i=1; i<=num_tables; i++)); do
        echo "Creating the table sbtest$i..."
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE test.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y';"
      done
    fi
  fi
}

run_crash_tests_pstress() {
    # This function crashes the server during load and then runs backup
    local test_type="$1"

    if [[ "${test_type}" = "encryption" ]]; then
      echo "Running crash tests with ${load_tool} and mysql running with encryption"
      if "${mysqldir}"/bin/mysqld --version | grep "8.0" >/dev/null 2>&1 ; then
        if ${mysqldir}/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then
          # Server is MS 8.0
          MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"
          load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0 --no-column-compression" # MS does not support column compression
        else
          # Server is PS 8.0
          MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
          load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0" # Used for pstress
        fi
      else
        # Server is MS/PS 5.7
        if "${mysqldir}"/bin/mysqld --version | grep "MySQL Community Server" >/dev/null 2>&1 ; then
          # Server is MS 5.7
          MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
          # Run pstress without ddl
          load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0 --no-ddl --no-column-compression"
        else
          # Server is PS 5.7 --innodb-temp-tablespace-encrypt is not GA and is deprecated
          MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-binlog --encrypt-tmp-files --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
          # Run pstress
          load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0"
        fi
      fi
      BACKUP_PARAMS="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
      PREPARE_PARAMS="${BACKUP_PARAMS}"
      RESTORE_PARAMS="${BACKUP_PARAMS}"
    elif [[ "${test_type}" = "rocksdb" ]]; then
      echo "Running crash tests with ${load_tool} for rocksdb"
      MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
      BACKUP_PARAMS="--core-file --lock-ddl"
      PREPARE_PARAMS="--core-file"
      RESTORE_PARAMS=""
      load_options="--tables 10 --records 1000 --threads 10 --seconds 150 --no-encryption --engine=rocksdb"
    else
      echo "Running crash tests with ${load_tool}"
      MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
      BACKUP_PARAMS="--core-file --lock-ddl"
      PREPARE_PARAMS="--core-file"
      RESTORE_PARAMS=""
      if [ $MS -eq 1 ]; then
        load_options="--tables 10 --records 200 --threads 5 --no-encryption --undo-tbs-sql 0 --no-column-compression"
      else
        load_options="--tables 10 --records 200 --threads 5 --no-encryption --undo-tbs-sql 0"
      fi
    fi

    if [ -d "${backup_dir}" ]; then
        rm -r "${backup_dir}"
    fi
    mkdir "${backup_dir}"
    log_date=$(date +"%d_%m_%Y_%M")

    cleanup
    initialize_db
    if [ "$test_type" = "rocksdb" ]; then
      $mysqldir/bin/ps-admin --enable-rocksdb -uroot -S${mysqldir}/socket.sock >/dev/null 2>&1
    fi

    if [[ "$2" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="${BACKUP_PARAMS} --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    echo "=>Run pstress to prepare metadata: ${load_options}"
    pushd "$tool_dir" >/dev/null 2>&1 || exit
    ./pstress-ps ${load_options} --prepare --exact-initial-records --logdir=${logdir}/pstress --socket ${mysqldir}/socket.sock >"${logdir}"/pstress/pstress_prepare.log
    popd >/dev/null 2>&1 || exit
    echo "..Metadata created"
    run_load "${load_options} --step 2"
    echo "=>Taking full backup"
    rr "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "..Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    # Save the full backup dir
    cp -pr ${backup_dir}/full ${backup_dir}/full_save

    sleep 1

    if [ -d ${mysqldir}/data_crash_save1 ]; then
            rm -r ${mysqldir}/data_crash_save1
    fi

    echo "Crash the mysql server"
    {  kill -15 $MPID && wait $MPID; } 2>/dev/null
    cp -pr ${mysqldir}/data ${mysqldir}/data_crash_save1

    start_server
    run_load "${load_options} --step 3"

    for inc_num in $(seq 1 4); do
      echo "Taking incremental backup: $inc_num"
      if [ ${inc_num} -eq 1 ]; then
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_backup_${log_date}_log
      else
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/inc$((inc_num - 1)) -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_backup_${log_date}_log
      fi
      if [ "$?" -ne 0 ]; then
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
        exit 1
      else
        echo "Inc backup was successfully created at: ${backup_dir}/inc${inc_num} Logs available at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
      fi

      # Save the incremental backup dir
      cp -pr ${backup_dir}/inc${inc_num} ${backup_dir}/inc${inc_num}_save
    done

    echo "Crash the mysql server"
    {  kill -15 $MPID && wait $MPID; } 2>/dev/null
    cp -pr ${mysqldir}/data ${mysqldir}/data_crash_save2
    start_server
    run_load "${load_options} --step 4"

    for ((inc_num=5;inc_num<9;inc_num++)); do
      echo "Taking incremental backup: $inc_num"
      if [ ${inc_num} -eq 1 ]; then
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_${i}_backup_${log_date}_log
      else
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/inc$((inc_num - 1)) -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_backup_${log_date}_log
      fi
      if [ "$?" -ne 0 ]; then
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
        exit 1
      else
        echo "Inc backup was successfully created at: ${backup_dir}/inc${inc_num} Logs available at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
      fi

      # Save the incremental backup dir
      cp -pr ${backup_dir}/inc${inc_num} ${backup_dir}/inc${inc_num}_save
    done

    echo "Preparing full backup"
    rr ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=${backup_dir}/full ${PREPARE_PARAMS} 2>${logdir}/prepare_full_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    for ((i=1; i<$inc_num; i++)); do
      echo "Preparing incremental backup: $i"
        if [[ "${i}" -eq "${inc_num}-1" ]]; then
          rr ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc${i} ${PREPARE_PARAMS} 2>${logdir}/prepare_inc${i}_backup_${log_date}_log
        else
          rr ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc${i} ${PREPARE_PARAMS} 2>${logdir}/prepare_inc${i}_backup_${log_date}_log
        fi
      if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
        exit 1
      else
        echo "Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
      fi
    done

    echo "Stopping mysql server and moving data directory"
    "${mysqldir}"/bin/mysqladmin -uroot -S"${mysqldir}"/socket.sock shutdown
    if [ -d "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")" ]; then
        rm -r "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")"
    fi
    mv "${mysqldir}"/data "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")"

    echo "Restoring full backup"
    "${xtrabackup_dir}"/xtrabackup --no-defaults --copy-back --target-dir="${backup_dir}"/full --datadir="${datadir}" ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
        exit 1
    else
        echo "Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
    fi

    start_server

    # Binlog can't be applied if binlog is encrypted or skipped
    if [[ "${MYSQLD_OPTIONS}" != *"binlog-encryption"* ]] && [[ "${MYSQLD_OPTIONS}" != *"--encrypt-binlog"* ]] && [[ "${MYSQLD_OPTIONS}" != *"skip-log-bin"* ]]; then
        echo "Check xtrabackup for binlog position"
        xb_binlog_file=$(cat "${backup_dir}"/full/xtrabackup_binlog_info|awk '{print $1}'|head -1)
        xb_binlog_pos=$(cat "${backup_dir}"/full/xtrabackup_binlog_info|awk '{print $2}'|head -1)
        echo "Xtrabackup binlog position: $xb_binlog_file, $xb_binlog_pos"

        echo "Applying binlog to restored data starting from $xb_binlog_file, $xb_binlog_pos"
        "${mysqldir}"/bin/mysqlbinlog "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")/$xb_binlog_file --start-position=$xb_binlog_pos | "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock
        if [ "$?" -ne 0 ]; then
            echo "ERR: The binlog could not be applied to the restored data"
        fi
        sleep 5
    else
        echo "Binlog applying skipped, ignore differences between actual data and restored data"

    fi

}

run_load() {
  # This function runs a load using pquery/sysbench
  local tool_options="$1"
  if [[ "${load_tool}" = "pstress" ]]; then
    echo "Run pstress with options: ${tool_options}"
    pushd "$tool_dir" >/dev/null 2>&1 || exit
    ./pstress-ps ${tool_options} --logdir=${logdir}/pstress --socket ${mysqldir}/socket.sock  > $logdir/pstress/pstress.log &
    popd >/dev/null 2>&1 || exit
    sleep 2
  else
    echo "Run sysbench"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=200 run >>"${logdir}"/sysbench.log &
  fi
}

take_backup() {
  # This function takes the incremental backup
  if [ -d "${backup_dir}" ]; then
    rm -r "${backup_dir}"
  fi
  mkdir "${backup_dir}"
  log_date=$(date +"%d_%m_%Y_%M")

  echo "=>Taking full backup"
  ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/full_backup_${log_date}_log
  if [ "$?" -ne 0 ]; then
    echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
    exit 1
  else
    echo "..Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
  fi

  sleep 1
  inc_num=1
  while [[ $(pgrep ${load_tool}) ]]; do
    echo "=>Taking incremental backup: $inc_num"
    if [[ "${inc_num}" -eq 1 ]]; then
      "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
    else
      "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
    fi
    if [ "$?" -ne 0 ]; then
      grep -e "PXB will not be able to make a consistent backup" -e "PXB will not be able to take a consistent backup" "${logdir}"/inc${inc_num}_backup_"${log_date}"_log
      if [ "$?" -eq 0 ]; then
        echo "Retrying incremental backup with --lock-ddl option"
        rm -r "${backup_dir}"/inc${inc_num}

        if [[ "${inc_num}" -eq 1 ]]; then
          "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --lock-ddl 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
        else
          "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --lock-ddl 2>>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
          if [ "$?" -ne 0 ]; then
            echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
            exit 1
          fi
        fi
      else
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
        exit 1
      fi
    else
      echo "..Inc backup was successfully created at: ${backup_dir}/inc${inc_num}. Logs available at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
    fi
    let inc_num++
    sleep 2
  done

  echo "=>Preparing full backup"
  "${xtrabackup_dir}"/xtrabackup --no-defaults --prepare --apply-log-only --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
  if [ "$?" -ne 0 ]; then
    echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
    exit 1
  else
    echo "..Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
  fi

  for ((i=1; i<inc_num; i++)); do
    echo "=>Preparing incremental backup: $i"
    if [[ "${i}" -eq "${inc_num}-1" ]]; then
      "${xtrabackup_dir}"/xtrabackup --no-defaults --prepare --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
    else
      "${xtrabackup_dir}"/xtrabackup --no-defaults --prepare --apply-log-only --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
    fi
    if [ "$?" -ne 0 ]; then
      echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
      exit 1
    else
      echo "..Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
    fi
  done

  echo "Collecting existing table count"
  pushd "$mysqldir" >/dev/null 2>&1 || exit
  pt-table-checksum S=${PWD}/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format| awk '{print $4,$9}' >file1
  popd >/dev/null 2>&1 || exit
  sleep 2

  echo "Stopping mysql server and moving data directory"
  ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock shutdown
  if [ -d "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")" ]; then
    rm -r "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")"
  fi
  mv "${mysqldir}"/data "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")"

  echo "=>Restoring full backup"
  "${xtrabackup_dir}"/xtrabackup --no-defaults --copy-back --target-dir="${backup_dir}"/full --datadir="${datadir}" ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
  if [ "$?" -ne 0 ]; then
    echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
    exit 1
  else
    echo "..Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
  fi

  start_server

  # Binlog can't be applied if binlog is encrypted or skipped
  if [[ "${MYSQLD_OPTIONS}" != *"binlog-encryption" ]] && [[ "${MYSQLD_OPTIONS}" != *"--encrypt-binlog"* ]] && [[ "${MYSQLD_OPTIONS}" != *"skip-log-bin"* ]]; then
    echo "Check xtrabackup for binlog position"
    xb_binlog_file=$(cat "${backup_dir}"/full/xtrabackup_binlog_info|awk '{print $1}'|head -1)
    xb_binlog_pos=$(cat "${backup_dir}"/full/xtrabackup_binlog_info|awk '{print $2}'|head -1)
    echo "Xtrabackup binlog position: $xb_binlog_file, $xb_binlog_pos"

    echo "Applying binlog to restored data starting from $xb_binlog_file, $xb_binlog_pos"
    "${mysqldir}"/bin/mysqlbinlog "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")/$xb_binlog_file --start-position=$xb_binlog_pos | "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock
    if [ "$?" -ne 0 ]; then
      echo "ERR: The binlog could not be applied to the restored data"
    fi
    sleep 3
  fi
}

start_server() {
  # This function starts the server
  echo "=>Starting MySQL server"
  rr $mysqldir/bin/mysqld --no-defaults --basedir=$mysqldir --datadir=$datadir $MYSQLD_OPTIONS --port=21000 --socket=$mysqldir/socket.sock --plugin-dir=$mysqldir/lib/plugin --max-connections=1024 --log-error=$datadir/error.log  --general-log --log-error-verbosity=3 --core-file > /dev/null 2>&1 &
  MPID="$!"

  for X in $(seq 0 ${mysql_start_timeout}); do
    sleep 1
    if ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock ping > /dev/null 2>&1; then
      echo "..Server started successfully"
      break
    fi
    if [ $X -eq ${mysql_start_timeout} ]; then
      echo "ERR: Database could not be started. Please check error logs: ${mysqldir}/data/error.log"
      exit 1
    fi
  done
}

run_load_tests() {
    # This function runs the load backup tests with normal options
    MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
    BACKUP_PARAMS="--core-file --lock-ddl"
    PREPARE_PARAMS="--core-file"
    RESTORE_PARAMS=""

    original_tool="${load_tool}"

    # Pstress options
    if [[ "$1" = "rocksdb" ]]; then
        echo "Test: Incremental Backup and Restore for rocksdb with ${load_tool}"
        tool_options="--tables 10 --records 200 --threads 10 --seconds 150 --no-encryption --engine=rocksdb"
    elif [[ "$1" = "memory_estimation" ]]; then
        if "${mysqldir}"/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
            echo "Memory estimation is not supported in PXB 2.4 version, skipping tests"
            return
        fi

        # This test can only be run using sysbench, since all ddl are blocked with lock-ddl
        load_tool="sysbench"

        echo "Test: Incremental Backup and Restore with ${load_tool} and using memory estimation"
        BACKUP_PARAMS="--core-file --lock-ddl"
        PREPARE_PARAMS="--core-file --use-free-memory-pct=20"
    else
        echo "Test: Incremental Backup and Restore with ${load_tool}"
        tool_options="--tables 10 --records 200 --threads 10 --seconds 30 --no-encryption --undo-tbs-sql 0"
	if [ $MS -eq 1 ]; then
	  tool_options="$tool_options --no-column-compression"
	fi
    fi

    cleanup
    initialize_db
    if [ "$1" = "rocksdb" ]; then
      ${mysqldir}/bin/ps-admin --enable-rocksdb -uroot -S${mysqldir}/socket.sock >/dev/null 2>&1
    fi

    if [[ "$1" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="--core-file --lock-ddl --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    run_load "${tool_options}"
    take_backup
    load_tool="${original_tool}"
}

cleanup() {
  echo "################################## CleanUp #######################################"
  echo "Killing any previously running mysqld process"
  MPID=( $(ps -ef | grep -e mysqld | grep error.log | grep -v grep | awk '{print $2}') )
  {  kill -15 $MPID && wait $MPID; } 2>/dev/null

  if [ -d $mysqldir/data ]; then
    echo "=>Found previously existing data directory"
    rm -rf $mysqldir/data
    echo "..Deleted"
  fi

  if [ -f $mysqldir/bin/mysqld.my ]; then
    echo "=>Found older manifest file in mysql bin directory"
    rm -rf $mysqldir/bin/mysqld.my
    echo "..Deleted"
  fi
  if [ -f $mysqldir/lib/plugin/component_keyring_file.cnf ]; then
    echo "=>Found older keyring_component config file in lib/plugin directory"
    rm -rf $mysqldir/lib/plugin/component_keyring_file.cnf
    echo "..Deleted"
  fi
  if [ -f $mysqldir/lib/plugin/component_keyring_file ]; then
    echo "=>Found older keyring_component keyfile in lib/plugin directory"
    rm -rf $mysqldir/lib/plugin/component_keyring_file
    echo "..Deleted"
  fi
}

if [ "$#" -lt 1 ]; then
    echo "This script tests backup with a load tool as pquery/pstress/sysbench"
    echo "Assumption: PS and PXB are already installed as tarballs"
    echo "Usage: "
    echo "1. Compile pquery/pstress with mysql"
    echo "2. Set variables in this script:"
    echo "   xtrabackup_dir, mysqldir, datadir, backup_dir, qascripts, logdir,"
    echo "   load_tool, tool_dir, num_tables, table_size, kmip, kms configuration"
    echo "3. Run the script as: $0 <Test Suites>"
    echo "   Test Suites: "
    echo "   Normal_and_Encryption_tests"
    echo "   Kmip_Encryption_tests"
    echo "   Kms_Encryption_tests"
    echo "   Rocksdb_tests"
    echo "   Page_Tracking_tests"
    echo " "
    echo "   Example:"
    echo "   $0 Normal_and_Encryption_tests Page_Tracking_tests"
    echo " "
    echo "4. Logs are available at: $logdir"
    exit 1
fi

if [ ! -d $logdir ]; then
  mkdir $logdir
fi
if [ ! -d $logdir/pstress ]; then
  mkdir $logdir/pstress
else
  rm -rf $logdir/pstress
  mkdir $logdir/pstress
fi

echo "################################## Running Tests ##################################"
for tsuitelist in $*; do
  case "${tsuitelist}" in
    Page_Tracking_tests)
      if "${mysqldir}"/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        echo "Page Tracking is not supported in MS/PS 5.7, skipping tests"
        return
      fi
      echo "Page Tracking Tests"
      for X in $(seq 1 10); do
	    run_crash_tests_pstress "encryption" "pagetracking"
      done
      ;;
  esac
done
