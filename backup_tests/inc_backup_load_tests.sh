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
export xtrabackup_dir="$HOME/pxb-9.1/bld_9.1/install/bin"
export mysqldir="$HOME/mysql-9.1/bld_9.1/install"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"
export mysql_start_timeout=60

# Set tool variables
load_tool="pstress" # Set value as pstress/sysbench
num_tables=25 # This will make 50 tables on the database tt_1, tt_1_p, .. tt_25, tt_25_p
table_size=100
seconds=60
threads=5
tool_dir="$HOME/pstress_9.1/src" # pstress dir

# PXB Lock option
LOCK_DDL=on # lock_ddl accepted values (on, reduced)

normalize_version() {
    local major=0
    local minor=0
    local patch=0
    # Everything after the first three values are ignored
    if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        patch=${BASH_REMATCH[3]}
    fi
    printf %02d%02d%02d $major $minor $patch
  }

VER=$($mysqldir/bin/mysqld --version | awk -F 'Ver ' '{print $2}' | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
VERSION=$(normalize_version $VER)

# Set Kmip configuration
setup_kmip() {
  # Kill and existing kmip server
  sudo pkill -9 kmip
  # Start KMIP server
  sleep 5
  sudo docker run -d --security-opt seccomp=unconfined --cap-add=NET_ADMIN --rm -p 5696:5696 --name kmip mohitpercona/kmip:latest
  if [ -d /tmp/certs ]; then
    echo "certs directory exists"
    rm -rf /tmp/certs
    mkdir /tmp/certs
  else
    echo "does not exist. creating certs dir"
    mkdir /tmp/certs
  fi
  sudo docker cp kmip:/opt/certs/root_certificate.pem /tmp/certs/
  sudo docker cp kmip:/opt/certs/client_key_jane_doe.pem /tmp/certs/
  sudo docker cp kmip:/opt/certs/client_certificate_jane_doe.pem /tmp/certs/

  kmip_server_address="0.0.0.0"
  kmip_server_port=5696
  kmip_client_ca="/tmp/certs/client_certificate_jane_doe.pem"
  kmip_client_key="/tmp/certs/client_key_jane_doe.pem"
  kmip_server_ca="/tmp/certs/root_certificate.pem"

  # Sleep for 30 sec to fully initialize the KMIP server
  sleep 30
}

# For kms tests set the values of KMS_REGION, KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY in the shell and then run the tests
kms_region="${KMS_REGION:-us-east-1}"  # Set KMS_REGION to change default value us-east-1
kms_id="${KMS_KEYID:-}"
kms_auth_key="${KMS_AUTH_KEY:-}"
kms_secret_key="${KMS_SECRET_KEY:-}"

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
  output=$($mysqldir/bin/mysql -uroot -S$mysqldir/socket.sock -Ne "SELECT COUNT(*) FROM information_schema.engines WHERE engine='InnoDB' AND comment LIKE 'Percona%';")
  if [ "$output" -eq 1 ]; then
      server_type="PS"
      echo "Test is running against: $server_type-$VER"
      if [ $load_tool == "pstress" ]; then
          PSTRESS_BINARY=pstress-ps
          if [ ! -f $tool_dir/pstress-ps ]; then
              echo "pstress-ps not found. Please compile pstress with Percona Server!"
              exit 1
          fi
      fi
  elif [ "$output" -eq 0 ]; then
      server_type="MS"
      echo "Test is running against: $server_type-$VER"
      if [ $load_tool == "pstress" ]; then
          PSTRESS_BINARY=pstress-ms
          if [ ! -f $tool_dir/pstress-ms ]; then
              echo "pstress-ms not found. Please compile pstress with Percona Server!"
              exit 1
          fi
      fi
  else
      echo "Invalid server version!"
      exit 1
  fi

  # Create data using sysbench
  if [[ "${load_tool}" = "sysbench" ]]; then
    if [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
      sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock prepare >"${logdir}"/sysbench.log
    else
      # Encryption enabled
      for ((i=1; i<=num_tables; i++)); do
        echo "Creating the table sbtest$i..."
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE test.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y';"
      done
    fi
  fi
}

run_load() {
    # This function runs a load using pstress/sysbench
    local tool_options="$1"
    if [[ "${load_tool}" = "pstress" ]]; then
        echo "Run pstress with options: ${tool_options}"
        pushd "$tool_dir" >/dev/null 2>&1 || exit
        if [ $LOCK_DDL == "reduced" ]; then
            ./$PSTRESS_BINARY ${tool_options} --rotate-master-key 0 --logdir=${logdir}/pstress --no-temp-tables --socket ${mysqldir}/socket.sock  > $logdir/pstress/pstress.log &
            popd >/dev/null 2>&1 || exit
        else
           ./$PSTRESS_BINARY ${tool_options} --logdir=${logdir}/pstress --no-temp-tables --socket ${mysqldir}/socket.sock  > $logdir/pstress/pstress.log &
        popd >/dev/null 2>&1 || exit
        fi
        sleep 2
    else
        echo "Run sysbench"
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=$seconds run >>${logdir}/sysbench.log &
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
  rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/full_backup_${log_date}_log
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
      rr "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --register-redo-log-consumer 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
    else
      rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --register-redo-log-consumer 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
    fi
    if [ "$?" -ne 0 ]; then
      grep -e "PXB will not be able to make a consistent backup" -e "PXB will not be able to take a consistent backup" "${logdir}"/inc${inc_num}_backup_"${log_date}"_log
      if [ "$?" -eq 0 ]; then
        echo "Retrying incremental backup with --lock-ddl option"
        rm -r "${backup_dir}"/inc${inc_num}

        if [[ "${inc_num}" -eq 1 ]]; then
          rr "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --lock-ddl=$LOCK_DDL --register-redo-log-consumer 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
        else
          rr "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --lock-ddl=$LOCK_DDL --register-redo-log-consumer 2>>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
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
    # Sleeping for 10 seconds before taking next inc backup. This is done because while backup is taken DDLs are blocked and pstress cannot proceed
    sleep 10
  done

  echo "=>Preparing full backup"
  rr "${xtrabackup_dir}"/xtrabackup --no-defaults --prepare --apply-log-only --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
  if [ "$?" -ne 0 ]; then
    echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
    exit 1
  else
    echo "..Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
  fi

  for ((i=1; i<inc_num; i++)); do
    echo "=>Preparing incremental backup: $i"
    if [[ "${i}" -eq "${inc_num}-1" ]]; then
      rr "${xtrabackup_dir}"/xtrabackup --no-defaults --prepare --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
    else
      rr "${xtrabackup_dir}"/xtrabackup --no-defaults --prepare --apply-log-only --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
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

    sleep 5

    echo "Collecting table count after restore"
	pushd "$mysqldir" >/dev/null 2>&1 || exit
    pt-table-checksum S=${PWD}/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format| awk '{print $4,$9}' >file2
    popd >/dev/null 2>&1 || exit
    diff $mysqldir/file1 $mysqldir/file2
    if [ "$?" -ne 0 ]; then
      echo "ERR: Difference found in table count before and after restore."
    else
      echo "Data is the same before and after restore: Pass"
	  rm -rf $mysqldir/file1 $mysqldir/file2
    fi
  else
    echo "Binlog applying skipped, ignore differences between actual data and restored data"
  fi
}

count_rows() {
    # This function counts the rows of all the tables in a database

    if [ ! -z "$1" ]; then
        database="$1"
    else
        database=test
    fi

    while read table; do
        echo -n "Row count for $database.$table: "
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "select count(*) from $database.$table"
    done < <("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "SHOW TABLES FROM $database;")

    while read table; do
        echo -n "Checksum of table $database.$table: "
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "checksum table $database.$table"|awk '{print $2}'
    done < <("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "SHOW TABLES FROM $database;")
}

check_tables() {
    # This function checks the tables in a database

    echo "Check the table status"
    check_err=0

    while read table; do
        echo "Checking table $table ..."
        if ! table_status=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "CHECK TABLE test.$table"|cut -f4-); then
            echo "ERR: CHECK TABLE test.$table query failed"
            # Check if database went down
            if ! "${mysqldir}"/bin/mysqladmin ping --user=root --socket="${mysqldir}"/socket.sock >/dev/null 2>&1; then
                echo "ERR: The database has gone down due to corruption in table test.$table"
                exit 1
            fi
        fi

        if [[ "$table_status" != "OK" ]]; then
            echo "ERR: CHECK TABLE test.$table query displayed the table status as '$table_status'"
            check_err=1
        fi
    done < <("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "SHOW TABLES FROM test;")

    # Check if database went down
    if ! "${mysqldir}"/bin/mysqladmin ping --user=root --socket="${mysqldir}"/socket.sock >/dev/null 2>&1; then
        echo "ERR: The database has gone down due to corruption, the restore was unsuccessful"
        exit 1
    fi

    if [[ "$check_err" -eq 0 ]]; then
        echo "All innodb tables status: OK"
    else
        echo "After restore, some tables may be corrupt, check table status is not OK"
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
    BACKUP_PARAMS="--core-file --lock-ddl=$LOCK_DDL"
    PREPARE_PARAMS="--core-file"
    RESTORE_PARAMS=""

    original_tool="${load_tool}"

    # Pstress options
    if [[ "$1" = "rocksdb" ]]; then
        echo "Test: Incremental Backup and Restore for rocksdb with ${load_tool}"
        tool_options="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --no-encryption --engine=rocksdb"
    elif [[ "$1" = "memory_estimation" ]]; then
        if "${mysqldir}"/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
            echo "Memory estimation is not supported in PXB 2.4 version, skipping tests"
            return
        fi

        # This test can only be run using sysbench, since all ddl are blocked with lock-ddl
        load_tool="sysbench"

        echo "Test: Incremental Backup and Restore with ${load_tool} and using memory estimation"
        BACKUP_PARAMS="--core-file --lock-ddl=$LOCK_DDL"
        PREPARE_PARAMS="--core-file --use-free-memory-pct=20"
    else
        echo "Test: Incremental Backup and Restore with ${load_tool}"
        tool_options="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --no-encryption --undo-tbs-sql 0"
	    if [ "$server_type" == "MS" ]; then
            tool_options="$tool_options --no-column-compression --no-temp-tables"
        fi
    fi

    cleanup
    initialize_db
    if [ "$1" = "rocksdb" ]; then
      ${mysqldir}/bin/ps-admin --enable-rocksdb -uroot -S${mysqldir}/socket.sock >/dev/null 2>&1
      ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e"CREATE DATABASE IF NOT EXISTS test"  >/dev/null 2>&1
    fi

    if [[ "$1" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="--core-file --lock-ddl=$LOCK_DDL --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    run_load "${tool_options}"
    take_backup
    check_tables
    load_tool="${original_tool}"
}

run_load_keyring_plugin_tests() {
    # This function runs the load backup tests with keyring_file plugin options
    BACKUP_PARAMS="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file --lock-ddl=$LOCK_DDL"
    PREPARE_PARAMS="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
    RESTORE_PARAMS="${PREPARE_PARAMS}"

    if [ $VERSION -ge 080000 ]; then
        if [ "$server_type" == "MS" ]; then
            # Server is MS 8.0
            MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"
            tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --undo-tbs-sql 0 --no-column-compression" # Used for pstress
        else
            # Server is PS 8.0
            MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
            tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --undo-tbs-sql 0" # Used for pstress
        fi
    elif [ $VERSION -lt 080000 ]; then
        if [ "$server_type" == "MS" ]; then
            # Server is MS 5.7
            MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
            # Run pstress without ddl
            tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --undo-tbs-sql 0 --no-ddl --no-column-compression"
        else
            # Server is PS 5.7 --innodb-temp-tablespace-encrypt is not GA and is deprecated
            MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-binlog --encrypt-tmp-files --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
            # Run pstress without temp tables encryption - existing issue PXB-2534
            tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --undo-tbs-sql 0 --no-temp-tables"
        fi
    fi

    echo "Test: Incremental Backup and Restore for keyring_file plugin with ${load_tool}"
    cleanup
    initialize_db

  if [[ "$1" = "pagetracking" ]]; then
    echo "Running test with page tracking enabled"
    BACKUP_PARAMS="${BACKUP_PARAMS} --page-tracking"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
  fi

  run_load "${tool_options_encrypt}"
  take_backup
  check_tables
}

create_keyring_component_files() {
    echo "Create global manifest file"
    cat <<-EOF >"${mysqldir}"/bin/mysqld.my
    {
      "components": "file://component_keyring_file"
    }
EOF
    if [[ ! -f "${mysqldir}"/bin/mysqld.my ]]; then
      echo "ERR: The global manifest could not be created in ${mysqldir}/bin/mysqld.my"
      exit 1
    fi

    echo "Create global configuration file"
    cat <<-EOF >"${mysqldir}"/lib/plugin/component_keyring_file.cnf
    {
        "path": "$mysqldir/lib/plugin/component_keyring_file",
        "read_only": false
    }
EOF
    if [[ ! -f "${mysqldir}"/lib/plugin/component_keyring_file.cnf ]]; then
        echo "ERR: The global configuration could not be created in ${mysqldir}/lib/plugin/component_keyring_file.cnf"
        exit 1
    fi

}

run_load_keyring_component_tests() {

    # This function runs the load backup tests with keyring_file component options
    BACKUP_PARAMS="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file --lock-ddl=$LOCK_DDL"
    PREPARE_PARAMS="${BACKUP_PARAMS} --component-keyring-config="${mysqldir}"/lib/plugin/component_keyring_file.cnf"
    RESTORE_PARAMS="${BACKUP_PARAMS}"

    if [ $VERSION -ge 080000 ]; then
        if [ "$server_type" == "MS" ]; then
        # Server is MS 8.0
        MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"
        elif [ "$server_type" == "PS" ]; then
            # Server is PS 8.0
            MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
        fi
    else
        # Server is MS/PS 5.7
        echo "Component is not supported in MS/PS 5.7, skipping tests"
        return
    fi

    echo "Test: Incremental Backup and Restore for keyring_file component with ${load_tool}"
    cleanup
    create_keyring_component_files

    if [ "$server_type" == "MS" ]; then
      tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds 50 --undo-tbs-sql 0 --no-column-compression"
    else
      tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds 50 --undo-tbs-sql 0" # Used for pstress
    fi
    initialize_db

    if [[ "$1" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="${BACKUP_PARAMS} --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    run_load "${tool_options_encrypt}"
    take_backup
    check_tables
}

run_load_kmip_component_tests() {
  # This function runs the load backup tests with keyring_kmip component options
  BACKUP_PARAMS="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
  PREPARE_PARAMS="${BACKUP_PARAMS} --component-keyring-config="${mysqldir}"/lib/plugin/component_keyring_kmip.cnf"
  RESTORE_PARAMS="${BACKUP_PARAMS}"

  if [ $VERSION -ge 080000 ]; then
      if [ "$server_type" == "MS" ]; then
          # Server is MS 8.0
          echo "MS 8.0 does not support keyring kmip for encryption, skipping keyring kmip tests"
          return
      else
          # Server is PS 8.0
          MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
      fi
  else
      # Server is MS/PS 5.7
      echo "Kmip Component is not supported in MS/PS 5.7, skipping tests"
      return
  fi

  echo "Test: Incremental Backup and Restore for keyring_kmip component with ${load_tool}"
  cleanup
  setup_kmip
  echo "Create global manifest file"
  cat <<-EOF >"${mysqldir}"/bin/mysqld.my
    {
        "components": "file://component_keyring_kmip"
    }
EOF
  if [[ ! -f "${mysqldir}"/bin/mysqld.my ]]; then
    echo "ERR: The global manifest could not be created in ${mysqldir}/bin/mysqld.my"
    exit 1
  fi

  echo "Create global configuration file"
  cat <<-EOF >"${mysqldir}"/lib/plugin/component_keyring_kmip.cnf
    {
        "path": "$mysqldir/keyring_kmip", "server_addr": "$kmip_server_address", "server_port": "$kmip_server_port", "client_ca": "$kmip_client_ca", "client_key": "$kmip_client_key", "server_ca": "$kmip_server_ca"
    }
EOF
  if [[ ! -f "${mysqldir}"/lib/plugin/component_keyring_kmip.cnf ]]; then
    echo "ERR: The global configuration could not be created in ${mysqldir}/lib/plugin/component_keyring_kmip.cnf"
    exit 1
  fi

  tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --undo-tbs-sql 0" # Used for pstress
  initialize_db

  if [[ "$1" = "pagetracking" ]]; then
    echo "Running test with page tracking enabled"
    BACKUP_PARAMS="${BACKUP_PARAMS} --page-tracking"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
  fi

  run_load "${tool_options_encrypt}"
  take_backup
  check_tables

  # Remove keyring component configuration so that test suites after this test suite can run without encryption
  if [[ -f "${mysqldir}"/bin/mysqld.my ]]; then
    rm "${mysqldir}"/bin/mysqld.my
  fi

  if [[ -f "${mysqldir}"/lib/plugin/component_keyring_kmip.cnf ]]; then
    rm "${mysqldir}"/lib/plugin/component_keyring_kmip.cnf
  fi
}

run_load_kms_component_tests() {
    # This function runs the load backup tests with keyring_kms component options
    BACKUP_PARAMS="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
    PREPARE_PARAMS="${BACKUP_PARAMS} --component-keyring-config="${mysqldir}"/lib/plugin/component_keyring_kms.cnf"
    RESTORE_PARAMS="${BACKUP_PARAMS}"

    if [ $VERSION -ge 080000 ]; then
        if [ "$server_type" == "MS" ]; then
            # Server is MS 8.0
            echo "MS 8.0 does not support keyring kms for encryption, skipping keyring kms tests"
            return
        else
            # Server is PS 8.0
            MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
        fi
    else
        # Server is MS/PS 5.7
        echo "Kms Component is not supported in MS/PS 5.7, skipping tests"
        return
    fi

    echo "Test: Incremental Backup and Restore for keyring_kms component with ${load_tool}"

    # Set KMS_REGION, KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY to create the kms configuration file
    if [[ -z "${kms_id}" ]]; then
        echo "ERR: KMS_KEYID is not set. Please set the value of KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY and run the kms tests again."
        exit 1
    fi

    if [[ -z "${kms_auth_key}" ]]; then
        echo "ERR: KMS_AUTH_KEY is not set. Please set the value of KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY and run the kms tests again."
        exit 1
    fi

    if [[ -z "${kms_secret_key}" ]]; then
        echo "ERR: KMS_SECRET_KEY is not set. Please set the value of KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY and run the kms tests again."
        exit 1
    fi

    if [[ -z "${kms_region}" ]]; then
        echo "ERR: KMS_REGION is not set. Please set the value of KMS_REGION, KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY and run the kms tests again."
        exit 1
    fi

    echo "Create global manifest file"
    cat <<EOF >"${mysqldir}"/bin/mysqld.my
{
    "components": "file://component_keyring_kms"
}
EOF
    if [[ ! -f "${mysqldir}"/bin/mysqld.my ]]; then
        echo "ERR: The global manifest could not be created in ${mysqldir}/bin/mysqld.my"
        exit 1
    fi

    echo "Create global configuration file"
    cat <<EOF >"${mysqldir}"/lib/plugin/component_keyring_kms.cnf
{
    "path": "$mysqldir/keyring_kms", "region": "us-east-1", "kms_key": "$KMS_KEYID", "auth_key": "$KMS_AUTH_KEY", "secret_access_key": "$KMS_SECRET_KEY", "read_only": false 
}
EOF
    if [[ ! -f "${mysqldir}"/lib/plugin/component_keyring_kms.cnf ]]; then
        echo "ERR: The global configuration could not be created in ${mysqldir}/lib/plugin/component_keyring_kms.cnf"
        exit 1
    fi

    tool_options_encrypt="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --undo-tbs-sql 0" # Used for pstress
    cleanup
    initialize_db

    if [[ "$1" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="${BACKUP_PARAMS} --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    run_load "${tool_options_encrypt}"
    take_backup
    check_tables

    # Remove keyring component configuration so that test suites after this test suite can run without encryption
    if [[ -f "${mysqldir}"/bin/mysqld.my ]]; then
        rm "${mysqldir}"/bin/mysqld.my
    fi

    if [[ -f "${mysqldir}"/lib/plugin/component_keyring_kms.cnf ]]; then
        rm "${mysqldir}"/lib/plugin/component_keyring_kms.cnf
    fi
}

run_crash_tests_pstress() {

    # This function crashes the server during load and then runs backup
    local test_type="$1"

    if [[ "${test_type}" = "encryption" ]]; then
        echo "Running crash tests with ${load_tool} and mysql running with encryption"
        if [ $VERSION -ge 080000 ]; then
            if [ "$server_type" == "MS" ]; then
                # Server is MS 8.0
                MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"
                load_options="--tables $num_tables --records $table_size --threads $threads --seconds 50 --undo-tbs-sql 0 --no-column-compression --no-temp-tables" # MS does not support column compression
            else
                # Server is PS 8.0
                MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
                load_options="--tables $num_tables --records $table_size --threads $threads --seconds 50 --undo-tbs-sql 0" # Used for pstress
            fi
        else
            if [ "$server_type" == "MS" ]; then
                # Server is MS 5.7
                MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
                # Run pstress without ddl
                load_options="--tables $num_tables --records $table_size --threads $threads --seconds 50 --undo-tbs-sql 0 --no-ddl --no-column-compression"
            else
                # Server is PS 5.7 --innodb-temp-tablespace-encrypt is not GA and is deprecated
                MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-binlog --encrypt-tmp-files --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
                # Run pstress
                load_options="--tables $num_tables --records $table_size --threads $threads --seconds 50 --undo-tbs-sql 0"
            fi
        fi
        BACKUP_PARAMS="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file --lock-ddl=$LOCK_DDL"
        PREPARE_PARAMS="${BACKUP_PARAMS} --component-keyring-config="${mysqldir}"/lib/plugin/component_keyring_file.cnf"
        RESTORE_PARAMS="${BACKUP_PARAMS}"
    elif [[ "${test_type}" = "rocksdb" ]]; then
        echo "Running crash tests with ${load_tool} for rocksdb"
        MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
        BACKUP_PARAMS="--core-file --lock-ddl=$LOCK_DDL"
        PREPARE_PARAMS="--core-file"
        RESTORE_PARAMS=""
        load_options="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --no-encryption --engine=rocksdb"
    else
        echo "Running crash tests with ${load_tool}"
        MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
        BACKUP_PARAMS="--core-file --lock-ddl=$LOCK_DDL"
        PREPARE_PARAMS="--core-file"
        RESTORE_PARAMS=""
        if [ "$server_type" == "MS" ]; then
            load_options="--tables $num_tables --records $table_size --threads $threads  --seconds $seconds --no-encryption --undo-tbs-sql 0 --no-column-compression"
        else
            load_options="--tables $num_tables --records $table_size --threads $threads --seconds $seconds --no-encryption --undo-tbs-sql 0"
        fi
    fi

    if [ -d "${backup_dir}" ]; then
        rm -r "${backup_dir}"
    fi
    mkdir "${backup_dir}"
    log_date=$(date +"%d_%m_%Y_%M")

    cleanup
    create_keyring_component_files
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
    ./$PSTRESS_BINARY ${load_options} --prepare --exact-initial-records --logdir=${logdir}/pstress --socket ${mysqldir}/socket.sock >"${logdir}"/pstress/pstress_prepare.log
    popd >/dev/null 2>&1 || exit
    echo "..Metadata created"
    run_load "${load_options} --step 2"
    echo "=>Taking full backup"
    rr "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --register-redo-log-consumer 2>"${logdir}"/full_backup_"${log_date}"_log
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
    {  kill -9 $MPID && wait $MPID; } 2>/dev/null
    cp -pr ${mysqldir}/data ${mysqldir}/data_crash_save1

    start_server
    run_load "${load_options} --step 3"

    for inc_num in $(seq 1 4); do
      echo "Taking incremental backup: $inc_num"
      if [ ${inc_num} -eq 1 ]; then
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/inc${inc_num}_backup_${log_date}_log
      else
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/inc$((inc_num - 1)) -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/inc${inc_num}_backup_${log_date}_log
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
    {  kill -9 $MPID && wait $MPID; } 2>/dev/null
    cp -pr ${mysqldir}/data ${mysqldir}/data_crash_save2
    start_server
    run_load "${load_options} --step 4"

    for ((inc_num=5;inc_num<9;inc_num++)); do
      echo "Taking incremental backup: $inc_num"
      if [ ${inc_num} -eq 1 ]; then
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/inc${inc_num}_${i}_backup_${log_date}_log
      else
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/inc$((inc_num - 1)) -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/inc${inc_num}_backup_${log_date}_log
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
    ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=${backup_dir}/full ${PREPARE_PARAMS} 2>${logdir}/prepare_full_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    for ((i=1; i<$inc_num; i++)); do
      echo "Preparing incremental backup: $i"
        if [[ "${i}" -eq "${inc_num}-1" ]]; then
          ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc${i} ${PREPARE_PARAMS} 2>${logdir}/prepare_inc${i}_backup_${log_date}_log
        else
          ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc${i} ${PREPARE_PARAMS} 2>${logdir}/prepare_inc${i}_backup_${log_date}_log
        fi
      if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
        exit 1
      else
        echo "Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
      fi
    done

    echo "Collecting existing table count"
    orig_data=$(count_rows)

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

        echo "Collecting table count after restore"
        res_data=$(count_rows)
        if [[ "${orig_data}" != "${res_data}" ]]; then
            echo "ERR: Data changed after restore."
            echo "Original data:"
            echo "${orig_data}"
            echo "Restored data:"
            echo "${res_data}"
        else
            echo "Data is the same before and after restore: Pass"
        fi
    else
        echo "Binlog applying skipped, ignore differences between actual data and restored data"

    fi

    check_tables
}

cleanup() {
  echo "################################## CleanUp #######################################"
  echo "Killing any previously running mysqld process"
  MPID=( $(ps -ef | grep -e mysqld | grep error.log | grep -v grep | awk '{print $2}') )
  {  kill -9 $MPID && wait $MPID; } 2>/dev/null

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
    Normal_and_Encryption_tests)
      run_load_tests
      echo "###################################################################################"
      if [ $VERSION -lt 080400 ]; then
          run_load_keyring_plugin_tests
      fi
      echo "###################################################################################"
      run_load_keyring_component_tests
      echo "###################################################################################"
      run_load_tests "memory_estimation"
      echo "###################################################################################"
      if [ $load_tool == "pstress" ]; then
          run_crash_tests_pstress "normal"
          echo "###################################################################################"
          run_crash_tests_pstress "encryption"
          echo "###################################################################################"
      fi
      ;;
    Kmip_Encryption_tests)
      run_load_kmip_component_tests
      echo "###################################################################################"
      run_load_kmip_component_tests "pagetracking"
      echo "###################################################################################"
      ;;
    Kms_Encryption_tests)
      run_load_kms_component_tests
      echo "###################################################################################"
      run_load_kms_component_tests "pagetracking"
      echo "###################################################################################"
      ;;
    Rocksdb_tests)
      if "${mysqldir}"/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        echo "Rocksdb backup is not supported in MS/PS 5.7, skipping tests"
	continue
      fi
      if ${mysqldir}/bin/mysqld --version | grep "MySQL Community Server" > /dev/null 2>&1 ; then
        echo "RocksDB is unsupported in MS, skipping tests"
        continue
      fi
      echo "Rocksdb Tests"
      run_load_tests "rocksdb"
      echo "###################################################################################"
      if [ $load_tool == "pstress" ]; then
          run_crash_tests_pstress "rocksdb"
      fi
      echo "###################################################################################"
      ;;
    Page_Tracking_tests)
      if "${mysqldir}"/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        echo "Page Tracking is not supported in MS/PS 5.7, skipping tests"
        return
      fi
      echo "Page Tracking Tests"
      run_load_tests "pagetracking"
      echo "###################################################################################"
      if [ $VERSION -lt 080400 ]; then
          run_load_keyring_plugin_tests "pagetracking"
      fi
      echo "###################################################################################"
      run_load_keyring_component_tests "pagetracking"
      echo "###################################################################################"
      if [ $load_tool == "pstress" ]; then
          run_crash_tests_pstress "normal" "pagetracking"
          echo "###################################################################################"
          run_crash_tests_pstress "encryption" "pagetracking"
          echo "###################################################################################"
          run_crash_tests_pstress "rocksdb" "pagetracking"
          echo "###################################################################################"
      fi
      ;;
  esac
done
