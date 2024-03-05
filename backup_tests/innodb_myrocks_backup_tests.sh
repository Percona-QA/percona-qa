#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup for innodb and myrocks tables               #
# Assumption: PS and PXB are already installed as tarballs             #
# Usage:                                                               #
# 1. Set paths in this script:                                         #
#    xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir, # 
#    vault_config, cloud_config                                        #
# 2. Set config variables in the script for                            #
#    sysbench, stream, encryption key, kmip, kms                       #
# 3. For usage run the script as: ./innodb_myrocks_backup_tests.sh     #
# 4. Logs are available in: logdir                                     #
########################################################################

# Set script variables
#export xtrabackup_dir="$HOME/pxb-8.2/bld_PXB_3034/install/bin"
export xtrabackup_dir="$HOME/pxb-8.3/bld_8.3/install/bin"
export mysqldir="$HOME/mysql-8.3/bld_8.3/install"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export datadir="${mysqldir}/data"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"
export cloud_config="$HOME/aws.cnf"  # Only required for cloud backup tests
export PATH="$PATH:$xtrabackup_dir"
rocksdb="disabled" # Set this to disabled for PXB2.4 and MySQL versions
server_type="PS" # Default server PS
install_type="tarball" # Set value to tarball/package

# Set sysbench variables
num_tables=10
table_size=1000
random_type=uniform

# Set stream and encryption key
backup_stream="backup.xbstream"
encrypt_key="mHU3Zs5sRcSB7zBAJP1BInPP5lgShKly"
backup_tar="backup.tar"

# Set user for backup
backup_user="root"

# Set Kmip configuration
kmip_server_address="0.0.0.0"
kmip_server_port=5696
kmip_client_ca="/home/manish.chawla/.local/etc/pykmip/client_certificate_john_smith.pem"
kmip_client_key="/home/manish.chawla/.local/etc/pykmip/client_key_john_smith.pem"
kmip_server_ca="/home/manish.chawla/.local/etc/pykmip/server_certificate.pem"

# For kms tests set the values of KMS_REGION, KMS_KEYID, KMS_AUTH_KEY, KMS_SECRET_KEY in the shell and then run the tests
kms_region="${KMS_REGION:-us-east-1}"  # Set KMS_REGION to change default value us-east-1
kms_id="${KMS_KEYID:-}"
kms_auth_key="${KMS_AUTH_KEY:-}"
kms_secret_key="${KMS_SECRET_KEY:-}"

# Start vault server
start_vault_server(){
  echo "Setting up vault server"
  if [ ! -d $HOME/vault ]; then
    mkdir $HOME/vault
  fi
  rm -rf $HOME/vault/*
  # Kill any previously running vault server
  killall vault > /dev/null 2>&1
  $qascripts/vault_test_setup.sh --workdir=$HOME/vault --use-ssl > /dev/null 2>&1
  vault_config="$HOME/vault/keyring_vault_ps.cnf"
  vault_url=$(grep 'vault_url' "$vault_config" | awk -F '=' '{print $2}' | tr -d '[:space:]')
  secret_mount_point=$(grep 'secret_mount_point' "$vault_config" | awk -F '=' '{print $2}' | tr -d '[:space:]')
  token=$(grep 'token' "$vault_config" | awk -F '=' '{print $2}' | tr -d '[:space:]')
  vault_ca=$(grep 'vault_ca' "$vault_config" | awk -F '=' '{print $2}' | tr -d '[:space:]')
}

# Below function is a hack-ish way to find out if the server type is PS or MS
find_server_type() {
  # Run mysqld --version and capture the output
  version_output=$($mysqldir/bin/mysqld --version)

  # Use awk to extract the version
  version=$(echo "$version_output" | awk '{print $3}')

  # Split the version into major and minor parts using "-" as delimiter
  IFS='-' read -ra parts <<< "$version"
  MAJOR_VER=$(echo "${parts[0]}")
  MINOR_VER=$(echo "${parts[1]}")

  if [ "$MINOR_VER" == "" ]; then
    server_type="MS"
  else
    server_type="PS"
  fi
}
normalize_version(){
  local major=0
  local minor=0
  local patch=0

  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
      major=${BASH_REMATCH[1]}
      minor=${BASH_REMATCH[2]}
      patch=${BASH_REMATCH[3]}
  fi
  printf %02d%02d%02d $major $minor $patch
}
VER=$($mysqldir/bin/mysqld --version | awk -F 'Ver ' '{print $2}' | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
PXB_VER=$($xtrabackup_dir/xtrabackup --no-defaults --version 2>&1 |  awk -F 'version' '{print $2}' | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
VERSION=$(normalize_version $VER)
PXB_VERSION=$(normalize_version $PXB_VER)

#set -o pipefail

initialize_db() {
    # This function initializes and starts mysql database
    local MYSQLD_OPTIONS="$1"

    if [ ! -d ${logdir} ]; then
        mkdir ${logdir}
    fi

    echo "Starting mysql database"
    pushd $mysqldir >/dev/null 2>&1
    if [ ! -f $mysqldir/all_no_cl ]; then
        $qascripts/startup.sh
    fi

    ./all_no_cl --log-bin=binlog ${MYSQLD_OPTIONS} >${logdir}/database_startup_log 2>${logdir}/database_startup_log
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Please check the directory. Log available at: ${logdir}/database_startup_log"
        popd >/dev/null 2>&1
        exit 1
    fi
    popd >/dev/null 2>&1

    echo "Creating innodb data in database"
    which sysbench >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Sysbench not found, data could not be created"
        exit 1
    fi

    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';"
    if [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
        # Create tables without encryption
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --rand-type=${random_type} prepare

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Creating rocksdb data in database"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test_rocksdb;"
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --rand-type=${random_type} prepare
    fi

    else
        # Create encrypted tables: changed the oltp_common.lua script to include mysql-table-options="Encryption='Y'"
        echo "Creating encrypted tables in innodb"
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --mysql-table-options="Encryption='Y'" --rand-type=${random_type} prepare >/dev/null 2>&1
        if [ "$?" -ne 0 ]; then
            for ((i=1; i<=${num_tables}; i++)); do
                echo "Creating the table sbtest$i..."
                ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y';"
            done

            echo "Adding data in tables..."
            sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=30 --rand-type=${random_type} run >/dev/null 2>&1 
        fi
    fi
}

process_backup() {
    # This function extracts a streamed backup, decrypts and uncompresses it
    local BK_TYPE="$1"
    local BK_PARAMS="$2"
    local EXT_DIR="$3"

    if [[ "${BK_TYPE}" = "stream" ]]; then
        if [ -z "${backup_dir}/${backup_stream}" ]; then
            echo "ERR: The backup stream file was not created in ${backup_dir}/${backup_stream}. Please check the backup logs in ${logdir} for errors."
            exit 1
        else
            echo "Extract the backup from the stream file at ${backup_dir}/${backup_stream}"
            ${xtrabackup_dir}/xbstream --directory=${EXT_DIR} --extract --verbose < ${backup_dir}/${backup_stream} 2>>${logdir}/extract_backup_${log_date}_log
            if [ "$?" -ne 0 ]; then
                echo "ERR: Extract of backup failed. Please check the log at: ${logdir}/extract_backup_${log_date}_log"
                exit 1
            else
                echo "Backup was successfully extracted. Logs available at: ${logdir}/extract_backup_${log_date}_log"
                #rm -r ${backup_dir}/${backup_stream}
            fi
        fi
    fi

    if [[ "${BK_PARAMS}" = *"--encrypt-key"* ]]; then
        echo "Decrypting the backup files at ${EXT_DIR}"
        ${xtrabackup_dir}/xtrabackup --decrypt=AES256 --encrypt-key=${encrypt_key} --target-dir=${EXT_DIR} --parallel=10 2>>${logdir}/decrypt_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Decrypt of backup failed. Please check the log at: ${logdir}/decrypt_backup_${log_date}_log"
            exit 1
        else
            echo "Backup was successfully decrypted. Logs available at: ${logdir}/decrypt_backup_${log_date}_log"
        fi
    fi

    if [[ "${BK_PARAMS}" = *"--compress"* ]]; then
        if ! which qpress 2>&1>/dev/null; then
            echo "ERR: The qpress package is not installed. It is required to decompress the backup."
            exit 1
        fi
        echo "Decompressing the backup files at ${EXT_DIR}"
        #${xtrabackup_dir}/xtrabackup --decompress --remove-original --parallel=100 --target-dir=${EXT_DIR} 2>>${logdir}/decompress_backup_${log_date}_log
        ${xtrabackup_dir}/xtrabackup --decompress --parallel=10 --target-dir=${EXT_DIR} 2>>${logdir}/decompress_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Decompress of backup failed. Please check the log at: ${logdir}/decompress_backup_${log_date}_log"
            exit 1
        else
            echo "Backup was successfully decompressed. Logs available at: ${logdir}/decompress_backup_${log_date}_log"
        fi
    fi
}

restart_db() {
    # This function restarts the mysql database
    local MYSQLD_OPTIONS="$1"

    ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock shutdown
    sleep 2
    pushd $mysqldir >/dev/null 2>&1
    ./start --log-bin=binlog ${MYSQLD_OPTIONS} >/dev/null 2>&1
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Database logs: ${mysqldir}/log"
        popd >/dev/null 2>&1
        exit 1
    fi
    popd >/dev/null 2>&1
}

incremental_backup() {
    # This function takes the incremental backup
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local RESTORE_PARAMS="$3"
    local MYSQLD_OPTIONS="$4"
    local BACKUP_TYPE="$5"
    local CLOUD_PARAMS="$6"

    log_date=$(date +"%d_%m_%Y_%M")
    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    if [ ! -d ${logdir} ]; then
        mkdir ${logdir}
    fi

    case "${BACKUP_TYPE}" in
        'cloud')
            echo "Taking full backup and uploading it"
            ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --extra-lsndir=${backup_dir} --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream 2>${logdir}/full_backup_${log_date}_log | ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} put full_backup_${log_date} 2>${logdir}/upload_full_backup_${log_date}_log
            ;;

        'stream')
            echo "Taking full backup and creating a stream file"
            ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream --parallel=10 > ${backup_dir}/${backup_stream} 2>${logdir}/full_backup_${log_date}_log
            ;;

        'tar')
            echo "Taking full backup and creating a tar file"
            # Note: The --stream=tar option does not support --parallel option
            ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=tar > ${backup_dir}/${backup_tar} 2>${logdir}/full_backup_${log_date}_log
            ;;

        *)
            echo "Taking full backup"
            ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/full_backup_${log_date}_log
            ;;
    esac
    if [ "$?" -ne 0 ]; then
        grep -e "PXB will not be able to make a consistent backup" -e "PXB will not be able to take a consistent backup" "${logdir}"/full_backup_"${log_date}"_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
            exit 1
        else
            return # Backup could not be completed due to DDL
        fi
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    if [ "${BACKUP_TYPE}" = "tar" ]; then
        if [ -z "${backup_dir}/${backup_tar}" ]; then
            echo "ERR: The backup tar file was not created in ${backup_dir}/${backup_tar}. Please check the backup logs in ${logdir} for errors."
            exit 1
        else
            echo "Extract the backup from the tar file at ${backup_dir}/${backup_tar}"
            tar -xvf ${backup_dir}/${backup_tar} -C ${backup_dir}/full >${logdir}/extract_backup_${log_date}_log
            if [ "$?" -ne 0 ]; then
                echo "ERR: Extract of backup failed using tar. Please check the log at: ${logdir}/extract_backup_${log_date}_log"
                exit 1
            else
                echo "Backup was successfully extracted. Logs available at: ${logdir}/extract_backup_${log_date}_log"
            fi
        fi
    fi

    if [ "${BACKUP_TYPE}" = "cloud" ]; then
        echo "Downloading full backup"
        ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} get full_backup_${log_date} 2>${logdir}/download_full_backup_${log_date}_log | ${xtrabackup_dir}/xbstream -xv -C ${backup_dir}/full 2>${logdir}/download_stream_full_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Download of Full Backup failed. Please check the log at: ${logdir}/download_full_backup_${log_date}_log and ${logdir}/download_stream_full_backup_${log_date}_log"
            exit 1
        else
            echo "Full backup was successfully downloaded at: ${backup_dir}/full"
        fi
    fi
    # Call function to process backup for streaming, encryption and compression
    process_backup "${BACKUP_TYPE}" "${BACKUP_PARAMS}" "${backup_dir}/full"

    echo "Adding data in database"
    # Innodb data
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=20 --rand-type=${random_type} run >/dev/null 2>&1 &

    # Rocksdb data
    if [ "${rocksdb}" = "enabled" ]; then
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=20 --rand-type=${random_type} run >/dev/null 2>&1 &
    fi
    sleep 10

    case "${BACKUP_TYPE}" in
        'cloud')
            echo "Taking incremental backup and uploading it"
            ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir} -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream 2>${logdir}/inc_backup_${log_date}_log | ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} put inc_backup_${log_date} 2>${logdir}/upload_inc_backup_${log_date}_log
            ;;

        'stream')
            echo "Taking incremental backup and creating a stream file"
            ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream --parallel=10 > ${backup_dir}/${backup_stream} 2>${logdir}/inc_backup_${log_date}_log
            ;;

            # Note: The --stream=tar option is not supported for incremental backup in PXB2.4

        *)
            echo "Taking incremental backup"
            rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=${backup_user} --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --register-redo-log-consumer 2>${logdir}/inc_backup_${log_date}_log
            ;;
    esac
    if [ "$?" -ne 0 ]; then
        grep -e "PXB will not be able to make a consistent backup" -e "PXB will not be able to take a consistent backup" "${logdir}"/inc_backup_"${log_date}"_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc_backup_${log_date}_log"
            exit 1
        else
            return # Backup could not be completed due to DDL
        fi
    else
        echo "Inc backup was successfully created at: ${backup_dir}/inc. Logs available at: ${logdir}/inc_backup_${log_date}_log"
    fi

    if [ "${BACKUP_TYPE}" = "cloud" ]; then
        echo "Downloading incremental backup"
        ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} get inc_backup_${log_date} 2>${logdir}/download_inc_backup_${log_date}_log | ${xtrabackup_dir}/xbstream -xv -C ${backup_dir}/inc 2>${logdir}/download_stream_inc_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Download of Inc Backup failed. Please check the log at: ${logdir}/download_inc_backup_${log_date}_log and ${logdir}/download_stream_inc_backup_${log_date}_log"
            exit 1
        else
            echo "Incremental backup was successfully downloaded at: ${backup_dir}/inc"
        fi
    fi

    if [ "${BACKUP_TYPE}" = "cloud" ]; then
        echo "Deleting full backup"
        ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} delete full_backup_${log_date} 2>${logdir}/delete_full_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Delete of Full Backup failed. Please check the log at: ${logdir}/delete_full_backup_${log_date}_log"
        else
            echo "Full backup was successfully deleted from the cloud"
        fi

        echo "Deleting incremental backup"
        ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} delete inc_backup_${log_date} 2>${logdir}/delete_inc_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Delete of Inc Backup failed. Please check the log at: ${logdir}/delete_inc_backup_${log_date}_log"
        else
            echo "Incremental backup was successfully deleted from the cloud"
        fi
    fi

    # Call function to process backup for streaming, encryption and compression
    process_backup "${BACKUP_TYPE}" "${BACKUP_PARAMS}" "${backup_dir}/inc"

    # Save the backup before prepare
    if [ -d $HOME/dbbackup_save ]; then
        rm -r $HOME/dbbackup_save
    fi
    cp -r ${backup_dir} $HOME/dbbackup_save

    echo "Preparing full backup"
    rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --prepare --apply-log-only --target_dir=${backup_dir}/full ${PREPARE_PARAMS} 2>${logdir}/prepare_full_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    echo "Preparing incremental backup"
    rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc ${PREPARE_PARAMS} 2>${logdir}/prepare_inc_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc_backup_${log_date}_log"
    fi

    echo "Restart mysql server to stop all running queries"
    restart_db "${MYSQLD_OPTIONS}"
    echo "The mysql server was restarted successfully"

    echo "Collecting current data of all tables"
    # Get record count and checksum for each table in test database
    for ((i=1; i<=${num_tables}; i++)); do
        rc_innodb_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test.sbtest$i;")
        chk_innodb_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
    done

    # Get record count and checksum of each table in test_rocksdb database
    if [[ "${rocksdb}" = "enabled" ]] && [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
        for ((i=1; i<=${num_tables}; i++)); do
            rc_myrocks_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test_rocksdb.sbtest$i;")
            chk_myrocks_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test_rocksdb.sbtest$i;"|awk '{print $2}')
        done
    fi

    echo "Stopping mysql server and moving data directory"
    ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock shutdown
    if [ -d ${mysqldir}/data_orig_$(date +"%d_%m_%Y") ]; then
        rm -r ${mysqldir}/data_orig_$(date +"%d_%m_%Y")
    fi
    mv ${mysqldir}/data ${mysqldir}/data_orig_$(date +"%d_%m_%Y")

    if [[ "${BACKUP_PARAMS}" = *"--transition-key"* ]] && [[ "${MYSQLD_OPTIONS}" != *"keyring_vault"* ]]; then
        echo "Moving keyring file from ${mysqldir} dir"
        if [ -f "${keyring_file}" ]; then
            mv "${keyring_file}" "${keyring_file}"_orig
        fi
        #mv ${mysqldir}/keyring ${mysqldir}/keyring_orig
    fi

    if [ -d "${mysqldir}"/binlog ]; then
        mv "${mysqldir}"/binlog/* ${mysqldir}/data_orig_$(date +"%d_%m_%Y")
        rm -r "${mysqldir}"/binlog
    fi

    echo "Restoring full backup"
    ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --copy-back --target-dir=${backup_dir}/full --datadir=${datadir} ${RESTORE_PARAMS} 2>${logdir}/res_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
        exit 1
    else
        echo "Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
    fi

    # Copy server certificates from original data dir
    cp -pr ${mysqldir}/data_orig_$(date +"%d_%m_%Y")/*.pem ${mysqldir}/data/

    echo "Starting mysql server"
    pushd $mysqldir >/dev/null 2>&1
    ./start --log-bin=binlog ${MYSQLD_OPTIONS} >/dev/null 2>&1 
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. The restore was unsuccessful. Database logs: ${mysqldir}/log"
        popd >/dev/null 2>&1
        exit 1
    fi
    popd >/dev/null 2>&1
    echo "The mysql server was started successfully"

    # Binlog can't be applied if binlog is encrypted or skipped
    if [[ "${MYSQLD_OPTIONS}" != *"binlog-encryption"* ]] && [[ "${MYSQLD_OPTIONS}" != *"--encrypt-binlog"* ]] && [[ "${MYSQLD_OPTIONS}" != *"skip-log-bin"* ]]; then
        echo "Check xtrabackup for binlog position"
        xb_binlog_file=$(cat ${backup_dir}/full/xtrabackup_binlog_info|awk '{print $1}'|head -1)
        xb_binlog_pos=$(cat ${backup_dir}/full/xtrabackup_binlog_info|awk '{print $2}'|head -1)
        echo "Xtrabackup binlog position: $xb_binlog_file, $xb_binlog_pos"

        echo "Applying binlog to restored data starting from $xb_binlog_file, $xb_binlog_pos"
        ${mysqldir}/bin/mysqlbinlog ${mysqldir}/data_orig_$(date +"%d_%m_%Y")/$xb_binlog_file --start-position=$xb_binlog_pos | ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock
        if [ "$?" -ne 0 ]; then
            echo "ERR: The binlog could not be applied to the restored data"
        fi

        sleep 5
    fi

    echo "Checking restored data"
    echo "Check the table status"
    check_err=0
    if [[ "${rocksdb}" = "enabled" ]] && [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
        database_list="test test_rocksdb"
    else
        database_list="test"
    fi

    for ((i=1; i<=${num_tables}; i++)); do
        for database in ${database_list}; do
            if ! table_status=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECK TABLE $database.sbtest$i"|cut -f4-); then
                echo "ERR: CHECK TABLE $database.sbtest$i query failed"
                # Check if database went down
                if ! ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1; then
                    echo "ERR: The database has gone down due to corruption in table $database.sbtest$i"
                    exit 1
                fi
                check_err=1
            fi

            if [[ "$table_status" != "OK" ]]; then
                echo "ERR: CHECK TABLE $database.sbtest$i query displayed the table status as '$table_status'"
                check_err=1
                exit 1
            fi
        done
    done

    # Check if database went down
    if ! ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1; then
        echo "ERR: The database has gone down due to corruption, the restore was unsuccessful"
        exit 1
    fi

    if [[ "$check_err" -eq 0 ]]; then
        echo "All innodb and myrocks tables status: OK"
    else
        echo "After restore, some tables may be corrupt, check table status is not OK"
    fi

    # Record count and checksum can't be checked if binlog encryption is enabled and binlogs are not applied
    if [[ "${MYSQLD_OPTIONS}" != *"binlog-encryption"* ]] && [[ "${MYSQLD_OPTIONS}" != *"--encrypt-binlog"* ]] && [[ "${MYSQLD_OPTIONS}" != *"skip-log-bin"* ]]; then
        echo "Check the record count of tables in databases: ${database_list}"
        # Get record count for each table in databases test and test_rocksdb
        rc_err=0
        checksum_err=0
        for ((i=1; i<=${num_tables}; i++)); do
            rc_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test.sbtest$i;")
            if [[ "${rc_innodb_orig[$i]}" -ne "${rc_innodb_res[$i]}" ]]; then
                echo "ERR: The record count of test.sbtest$i changed after restore. Record count in original data: ${rc_innodb_orig[$i]}. Record count in restored data: ${rc_innodb_res[$i]}."
                rc_err=1
            fi

            if [[ "${rocksdb}" = "enabled" ]] && [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
                rc_myrocks_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test_rocksdb.sbtest$i;")
                if [[ "${rc_myrocks_orig[$i]}" -ne "${rc_myrocks_res[$i]}" ]]; then
                    echo "ERR: The record count of test_rocksdb.sbtest$i changed after restore. Record count in original data: ${rc_myrocks_orig[$i]}. Record count in restored data: ${rc_myrocks_res[$i]}."
                    rc_err=1
                fi
            fi
        done
        if [[ "$rc_err" -eq 0 ]]; then
            echo "Match record count of tables in databases ${database_list} with original data: Pass"
        fi

        echo "Check the checksum of each table in databases: ${database_list}"
        # Get checksum of each table in databases test and test_rocksdb
        for ((i=1; i<=${num_tables}; i++)); do
            chk_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
            if [[ "${chk_innodb_orig[$i]}" -ne "${chk_innodb_res[$i]}" ]]; then
                echo "ERR: The checksum of test.sbtest$i changed after restore. Checksum in original data: ${chk_innodb_orig[$i]}. Checksum in restored data: ${chk_innodb_res[$i]}."
                checksum_err=1;
            fi

            if [[ "${rocksdb}" = "enabled" ]] && [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
                chk_myrocks_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test_rocksdb.sbtest$i;"|awk '{print $2}')
                if [[ "${chk_myrocks_orig[$i]}" -ne "${chk_myrocks_res[$i]}" ]]; then
                    echo "ERR: The checksum of test_rocksdb.sbtest$i changed after restore. Checksum in original data: ${chk_myrocks_orig[$i]}. Checksum in restored data: ${chk_myrocks_res[$i]}."
                    checksum_err=1;
                fi
            fi
        done

        if [[ "$checksum_err" -eq 0 ]]; then
            echo "Match checksum of all tables in databases ${database_list} with original data: Pass"
        fi

    fi

    echo "Check for gaps in primary sequence id of tables"
    gap_found=0
    #for database in test test_rocksdb; do
    for database in ${database_list}; do
        for ((i=1; i<=${num_tables}; i++)); do
            j=1
            while read line; do
                if [[ "$line" != "$j" ]]; then
                    echo "ERR: Gap found in $database.sbtest$i. Expected sequence number for ID is: $j. Actual sequence number for ID is: $line."
                    gap_found=1
                    return
                fi
                let j++
            done < <(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT id FROM $database.sbtest$i ORDER BY id ASC")
        done
    done

    if [[ "$gap_found" -eq 0 ]]; then
        echo "No gaps found in primary sequence id of tables: Pass"
    fi
}

change_storage_engine() {
    # This function changes the storage engine of a table

    echo "Change the storage engine of test.sbtest1 to MYISAM, INNODB continuously"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test.sbtest1 ENGINE=MYISAM;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test.sbtest1 ENGINE=INNODB;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Change the storage engine of test_rocksdb.sbtest1 to INNODB, ROCKSDB, MYISAM continuously"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=INNODB;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=ROCKSDB;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=MYISAM;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=ROCKSDB;" >/dev/null 2>&1
        done ) &
    fi
}

add_drop_index() {
    # This function adds and drops an index in a table

    echo "Add and drop an index in the test.sbtest1 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE INDEX kc on test.sbtest1 (k,c);" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ADD INDEX kc2 (k,c);" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc2 on test.sbtest1;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test.sbtest1;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ADD INDEX kc (k,c), ALGORITHM=COPY, LOCK=EXCLUSIVE;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test.sbtest1;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Add and drop an index in the test_rocksdb.sbtest1 table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE INDEX kc on test_rocksdb.sbtest1 (k,c);" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 ADD INDEX kc2 (k,c);" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc2 on test_rocksdb.sbtest1;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test_rocksdb.sbtest1;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 ADD INDEX kc (k,c), ALGORITHM=COPY, LOCK=EXCLUSIVE;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test_rocksdb.sbtest1;" >/dev/null 2>&1
        done ) &
    fi
}

rename_index() {
    # This function renames an index in a table

    echo "Rename an index in the test.sbtest1 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 RENAME INDEX k_1 TO k_2, ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 RENAME INDEX k_2 TO k_1, ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Rename an index in the test_rocksdb.sbtest1 table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 RENAME INDEX k_1 TO k_2, ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 RENAME INDEX k_2 TO k_1, ALGORITHM=INPLACE, LOCK=NONE;" >/dev/null 2>&1
        done ) &
    fi
}

add_drop_full_text_index() {
    # This function adds and drops a full text index in a table

    echo "Add and drop a full text index in the test.sbtest1 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE FULLTEXT INDEX full_index on test.sbtest1 (pad);" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX full_index on test.sbtest1;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Add and drop a full text index in the test_rocksdb.sbtest1 table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE FULLTEXT INDEX full_index on test_rocksdb.sbtest1 (pad);" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX full_index on test_rocksdb.sbtest1;" >/dev/null 2>&1
        done ) &
    fi
}

change_index_type() {
    # This function changes the index type in a table

    echo "Change the index type in the test.sbtest1 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 DROP INDEX k_1, ADD INDEX k_1(k) USING BTREE, ALGORITHM=INSTANT;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 DROP INDEX k_1, ADD INDEX k_1(k) USING HASH, ALGORITHM=INSTANT;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Change the index type in the test_rocksdb.sbtest1 table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 DROP INDEX k_1, ADD INDEX k_1(k) USING BTREE, ALGORITHM=INSTANT;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 DROP INDEX k_1, ADD INDEX k_1(k) USING HASH, ALGORITHM=INSTANT;" >/dev/null 2>&1
        done ) &
    fi
}

add_drop_spatial_index() {
    # This function adds data to a spatial table along with add/drop index

    echo "Adding data in spatial table: test.geom"
    a=1; b=2
    ( while true; do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "INSERT INTO test.geom VALUES(POINT($a,$b));" >/dev/null 2>&1
        let a++; let b++
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Add and drop a spacial index in the test.geom table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE SPATIAL INDEX spa_index on test.geom (g), ALGORITHM=INPLACE, LOCK=SHARED;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX spa_index on test.geom;" >/dev/null 2>&1
        done ) &
    fi
}

add_drop_tablespace() {
    # This function adds a table to a tablespace and then drops the table, tablespace

    echo "Add an innodb table to a tablespace and drop the table, tablespace"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLESPACE ts1 ADD DATAFILE 'ts1.ibd' Engine=InnoDB;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.sbtest1copy SELECT * from test.sbtest1;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1copy TABLESPACE ts1;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE test.sbtest1copy;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLESPACE ts1;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Add a rocksdb table and drop the table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test_rocksdb.sbrcopy$i Engine=ROCKSDB SELECT * from test.sbtest1;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE test_rocksdb.sbrcopy$i;" >/dev/null 2>&1
        done ) &
    fi
}

change_compression() {
    # This function changes the compression of a table

    echo "Change the compression of an innodb table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 compression='lz4';" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 compression='zlib';" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 compression='';" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Change the compression of a myrocks table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 comment = 'cfname=cf1';" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 comment = 'cfname=cf2';" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 comment = 'cfname=cf3';" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest1 comment = 'cfname=cf4';" >/dev/null 2>&1
        done ) &
    fi
}

change_row_format() {
    # This function changes the row format of a table

    echo "Change the row format of an innodb table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=COMPRESSED;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=DYNAMIC;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=COMPACT;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=REDUNDANT;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Change the row format of a myrocks table"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest2 ROW_FORMAT=COMPRESSED;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest2 ROW_FORMAT=DYNAMIC;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest2 ROW_FORMAT=FIXED;" >/dev/null 2>&1
        done ) &
    fi
}

add_data_transaction() {
    # This function adds data in both innodb and myrocks table in a single transaction

    echo "Create tables innodb_t for innodb data and myrocks_t for myrocks data"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.innodb_t(id int(11) PRIMARY KEY AUTO_INCREMENT, k int(11), c char(120), pad char(60), KEY k_1(k), KEY kc(k,c)) ENGINE=InnoDB;"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.myrocks_t(id int(11) PRIMARY KEY AUTO_INCREMENT, k int(11), c char(120), pad char(60), KEY k_1(k), KEY kc(k,c)) ENGINE=ROCKSDB;"

    echo "Insert data in both innodb_t and myrocks_t tables in a single transaction"
    a=1; b=11; c=101
    ( while true; do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "START TRANSACTION;
        INSERT INTO innodb_t(k, c, pad) VALUES($a, $b, $c);
        INSERT INTO myrocks_t(k, c, pad) VALUES($a, $b, $c);
        COMMIT;" test
        let a++; let b++; let c++
    done ) &
}

update_truncate_table() {
    # This function updates data in tables and then truncates it

    echo "Update an innodb table and then truncate it"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "SET @@SESSION.OPTIMIZER_SWITCH='firstmatch=ON';" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET c='Œ„´‰?Á¨ˆØ?”’';" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "OPTIMIZE TABLE test.sbtest1;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "TRUNCATE test.sbtest1;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Update a myrocks table and then truncate it"
        ( for ((i=1; i<=10; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test_rocksdb.sbtest2 SET c='Œ„´‰?Á¨ˆØ?”’';" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "OPTIMIZE TABLE test_rocksdb.sbtest2;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "TRUNCATE test_rocksdb.sbtest2;" >/dev/null 2>&1
        done ) &
    fi
}

create_drop_database() {
    # This function creates a database and drops it

    echo "Create a database test1_innodb, add data and then drop it"
    ( for ((i=1; i<=3; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test1_innodb;" >/dev/null 2>&1
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=1 --table-size=1000 --mysql-db=test1_innodb --mysql-user=root --threads=10 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock prepare >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test1_innodb.sbtest1 ADD COLUMN b JSON AS('{\"k1\": \"value\", \"k2\": [10, 20]}');" >/dev/null 2>&1
        # Create a multivalue index
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE INDEX jindex on test1_innodb.sbtest1( (CAST(b->'$.k2' AS UNSIGNED ARRAY)) );"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX jindex on test1_innodb.sbtest1;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test1_innodb.sbtest1 DROP COLUMN b;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP DATABASE test1_innodb;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Create a database test1_rocksdb, add data and then drop it"
        ( for ((i=1; i<=3; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test1_rocksdb;" >/dev/null 2>&1
            sysbench /usr/share/sysbench/oltp_insert.lua --tables=1 --table-size=1000 --mysql-db=test1_rocksdb --mysql-user=root --threads=10 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock prepare >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test1_rocksdb.sbtest1 ADD COLUMN b VARCHAR(255) DEFAULT '{"k1": "value", "k2": [10, 20]}';" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test1_rocksdb.sbtest1 DROP COLUMN b;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP DATABASE test1_rocksdb;" >/dev/null 2>&1
        done ) &
    fi
}

create_delete_encrypted_table() {
    # This function creates an encrypted table and deletes it

    echo "Create an encrypted table and delete it"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test_innodb;" >/dev/null 2>&1

    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test_innodb.sbtest1 (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y' COMPRESSION='lz4';" >/dev/null 2>&1
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=1 --mysql-db=test_innodb --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=1 run >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE test_innodb.sbtest1;" >/dev/null 2>&1
    done ) &
}

change_encryption() {
    # This function changes the encryption of a table

    echo "Change the encryption of a table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ENCRYPTION='N';"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ENCRYPTION='Y';"
    done ) &
}

compressed_column() {
    # This function compresses a table column

    echo "Compress a table column"

    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 MODIFY c VARCHAR(250) COLUMN_FORMAT COMPRESSED NOT NULL DEFAULT '';" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 MODIFY c CHAR(120) COLUMN_FORMAT DEFAULT NOT NULL DEFAULT '';" >/dev/null 2>&1
    done ) &
}

compression_dictionary() {
    # This function compresses a table column by using a compression dictionary

    echo "Create a compression dictionary and use it to compress a table column"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE COMPRESSION_DICTIONARY numbers('08566691963-88624912351-16662227201-46648573979-64646226163-77505759394-75470094713-41097360717-15161106334-50535565977');" >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "Skipping test as the compression dictionary sql was unsuccessful, the mysql server does not support it"
        return 1
    fi

    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest$i MODIFY c VARCHAR(250) COLUMN_FORMAT COMPRESSED WITH COMPRESSION_DICTIONARY numbers NOT NULL DEFAULT '';" >/dev/null 2>&1 
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest$i MODIFY c CHAR(120) COLUMN_FORMAT DEFAULT NOT NULL DEFAULT '';" >/dev/null 2>&1
    done ) &
}

partitioned_tables() {
    # This function creates partitioned tables

    echo "Create innodb partitioned tables"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE IF EXISTS sbtest1; DROP TABLE IF EXISTS sbtest2; DROP TABLE IF EXISTS sbtest3;" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest1 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY HASH(id) PARTITIONS 10;" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest2 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN (500), PARTITION p1 VALUES LESS THAN (1000), PARTITION p2 VALUES LESS THAN MAXVALUE);" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest3 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY KEY() PARTITIONS 5;" test

    echo "Add data for innodb partitioned tables"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=3 --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=5 run >/dev/null 2>&1

    echo "Create and drop some partitions from sbtest1 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 COALESCE PARTITION 5;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 PARTITION BY HASH(id) PARTITIONS 10;" >/dev/null 2>&1
    done ) &

    echo "Create and drop a partition from sbtest2 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 DROP PARTITION p2;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ADD PARTITION (PARTITION p2 VALUES LESS THAN MAXVALUE);" >/dev/null 2>&1
    done ) &

    echo "Rebuild, optimize and analyze partitions from sbtest3 table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest3 REBUILD PARTITION p0, p1;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest3 OPTIMIZE PARTITION p2;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest3 ANALYZE PARTITION p3,p4;" >/dev/null 2>&1
    done ) &

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Create myrocks partitioned tables"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE sbtest1; DROP TABLE sbtest2; DROP TABLE sbtest3;" test_rocksdb
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest1 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) ENGINE=ROCKSDB PARTITION BY HASH(id) PARTITIONS 10;" test_rocksdb
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest2 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) ENGINE=ROCKSDB PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN (500), PARTITION p1 VALUES LESS THAN (1000), PARTITION p2 VALUES LESS THAN MAXVALUE);" test_rocksdb
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest3 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) ENGINE=ROCKSDB PARTITION BY KEY() PARTITIONS 5;" test_rocksdb

        echo "Add data for myrocks partitioned tables"
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=3 --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=5 run >/dev/null 2>&1
    fi
}

grant_tables() {
    # This function creates a user, grants privileges and then drops it

    echo "Create a user, grant privileges and then drop it"
    ( while true; do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE USER 'bkpuser'@'localhost' IDENTIFIED BY 's3cret';" >/dev/null 2>&1 
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO 'bkpuser'@'localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP USER 'bkpuser'@'localhost';" >/dev/null 2>&1 
    done ) &
}

add_drop_invisible_column() {
    # This function adds an invisible column and then drops it

    echo "Add an invisible column and then drop it"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ADD COLUMN invisible int DEFAULT 1 invisible first;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET invisible = id;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 DROP COLUMN invisible;" >/dev/null 2>&1
    done ) &
}


add_drop_blob_column() {
    # This function adds a blob column and then drops it

    echo "Add an blob column and then drop it"
    ( for ((i=1; i<=30; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ADD COLUMN blob_col blob;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET blob_col = c;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET blob_col = NULL;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET blob_col = id;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET blob_col = NULL;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 DROP COLUMN blob_col;" >/dev/null 2>&1
    done ) &
}

add_drop_column_instant() {
    # This function adds a column, drops it using instant algorithm and truncates the table

    echo "Add a column and then drop it"
    for table in sbtest1 sbtest2 sbtest3 sbtest4 sbtest5; do
        ( for ((i=1; i<=20; i++)); do
            # Check if database is up otherwise exit the loop
            ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
            if [ "$?" -ne 0 ]; then
                break
            fi

            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.$table ADD COLUMN b CHAR(50) NOT NULL DEFAULT '' AFTER k, ALGORITHM=INSTANT;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.$table SET b = k;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.$table DROP COLUMN b, ALGORITHM=INSTANT;" >/dev/null 2>&1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "TRUNCATE TABLE test.$table;" >/dev/null 2>&1
        done ) &
    done
}

add_drop_column_algorithms() {
    # This function adds a column and then drops it using different algorithms

    echo "Add a column and then drop it"
    ( for ((i=1; i<=20; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi

        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 ADD COLUMN b CHAR(50) NOT NULL DEFAULT '' AFTER k, ALGORITHM=DEFAULT;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest1 SET b = k;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest1 DROP COLUMN b, ALGORITHM=DEFAULT;" >/dev/null 2>&1
    done ) &

    ( for ((j=1; j<=20; j++)); do
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ADD COLUMN b CHAR(50) NOT NULL DEFAULT '' AFTER k, ALGORITHM=INPLACE;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest2 SET b = k;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 DROP COLUMN b, ALGORITHM=INPLACE;" >/dev/null 2>&1
    done ) &

    ( for ((k=1; k<=20; k++)); do
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest3 ADD COLUMN b CHAR(50) NOT NULL DEFAULT '' AFTER k, ALGORITHM=COPY;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest3 SET b = k;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest3 DROP COLUMN b, ALGORITHM=COPY;" >/dev/null 2>&1
    done ) &

    ( for ((l=1; l<=20; l++)); do
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest4 ADD COLUMN b CHAR(50) NOT NULL DEFAULT '' AFTER k;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest4 SET b = k;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest4 DROP COLUMN b;" >/dev/null 2>&1
    done ) &

    ( for ((m=1; m<=20; m++)); do
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest5 ADD COLUMN b CHAR(50) NOT NULL DEFAULT '' AFTER k, ALGORITHM=INPLACE;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "UPDATE test.sbtest5 SET b = k;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest5 DROP COLUMN b, ALGORITHM=COPY;" >/dev/null 2>&1
    done ) &
}

###################################################################################
##                                  Test Suites                                  ##
###################################################################################

test_inc_backup() {
    # This test suite creates a database, takes a full backup, incremental backup and then restores the database

    echo "Test: Incremental Backup and Restore"

    initialize_db

    incremental_backup
}

test_chg_storage_eng() {
    # This test suite takes an incremental backup when the storage engine of a table is changed

    echo "Test: Backup and Restore during change in storage engine"
    
    change_storage_engine

    incremental_backup
}

test_add_drop_index() {
    # This test suite takes an incremental backup when an index is added and dropped

    echo "Test: Backup and Restore during add and drop index"

    add_drop_index

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
      if [ "$server_type" == "MS" ]; then
          incremental_backup "--lock-ddl-per-table"
      else
          incremental_backup "--lock-ddl"
      fi
    fi
}

test_rename_index() {
    # This test suite takes an incremental backup when an index is renamed

    echo "Test: Backup and Restore during rename index"

    rename_index

    incremental_backup
}

test_add_drop_full_text_index() {
    # This test suite takes an incremental backup when full text index is added and dropped

    echo "Test: Backup and Restore during add and drop full text index"

    add_drop_full_text_index

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

test_change_index_type() {
    # This test suite takes an incremental backup when an index type is changed

    echo "Test: Backup and Restore during index type change"

    change_index_type

    incremental_backup
}

test_spatial_data_index() {
    # This test suite takes an incremental backup when a spatial index is added and dropped"

    if [ $VERSION -lt 080000 ] ; then
        echo "Skipping Test: Backup and Restore during add and drop spatial index, for PS/MS-${VER} as it is not supported"
        return
    fi

    echo "Test: Backup and Restore during add and drop spatial index"
    echo "Creating a table with spatial data"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.geom (g GEOMETRY NOT NULL SRID 0);"

    add_drop_spatial_index

    incremental_backup
}

test_add_drop_tablespace() {
    # This test suite takes an incremental backup when a tablespace is added and dropped

    echo "Test: Backup and Restore during add and drop tablespace"

    add_drop_tablespace

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

test_change_compression() {
    # This test suite takes an incremental backup when the compression of a table is changed

    echo "Test: Backup and Restore during change in compression"


    if [ "${rocksdb}" = "enabled" ]; then
        # Restart db with rocksdb compression options
        echo "Restart db with rocksdb compression options"
        restart_db "--rocksdb_override_cf_options=cf1={compression=kZlibCompression};cf2={compression=kLZ4Compression};cf3={compression=kZSTDNotFinalCompression};cf4={compression=kNoCompression}"

        change_compression

        incremental_backup "" "" "" "--rocksdb_override_cf_options=cf1={compression=kZlibCompression};cf2={compression=kLZ4Compression};cf3={compression=kZSTDNotFinalCompression};cf4={compression=kNoCompression}" "" ""

        # Initialize database to reset rocksdb compression options
        initialize_db
    else
        change_compression

        incremental_backup
    fi
}

test_change_row_format() {
    # This test suite takes an incremental backup when the row format of a table is changed

    echo "Test: Backup and Restore during change in row format"

    change_row_format

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

test_copy_data_across_engine() {
    # This test suite copies a table from one storage engine to another and then takes an incremental backup

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Test: Backup and Restore after cross engine table copy"

        innodb_checksum=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest1;"|awk '{print $2}')
        echo "Checksum of innodb table test.sbtest1: $innodb_checksum"

        echo "Copy the innodb table test.sbtest1 to myrocks table test_rocksdb.sbtestcopy"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test_rocksdb.sbtestcopy LIKE test_rocksdb.sbtest1;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "INSERT INTO test_rocksdb.sbtestcopy SELECT * FROM test.sbtest1;"

        incremental_backup

        myrocks_checksum=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test_rocksdb.sbtestcopy;"|awk '{print $2}')
        if [ "$innodb_checksum" -ne "$myrocks_checksum" ]; then
            echo "ERR: The checksum of tables after backup/restore changed. Checksum of innodb table test.sbtest1 before backup: $innodb_checksum. Checksum of myrocks table test_rocksdb.sbtestcopy after restore: $myrocks_checksum."
        else
            echo "Checksum of myrocks table test_rocksdb.sbtestcopy after restore: $myrocks_checksum"
            echo "Match checksum of test.sbtest1 with test_rocksdb.sbtestcopy: Pass"
        fi
    else
        echo "Skipping Test: Backup and Restore after cross engine table copy, as rocksdb is disabled"
    fi
}

test_add_data_across_engine() {
    # This test suite adds data in tables of innodb, rocksdb engines simultaneously

    if [ "${rocksdb}" = "enabled" ]; then
        echo "Test: Backup and Restore when data is added in both innodb and myrocks tables simultaneously"

        add_data_transaction

        incremental_backup

        echo "Check the row count of tables innodb_t and myrocks_t after restore"
        innodb_count=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT count(*) FROM test.innodb_t;")
        myrocks_count=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT count(*) FROM test.myrocks_t;")
        if [ "$innodb_count" -ne "$myrocks_count" ]; then
            echo "ERR: The row count of tables innodb_t and myrocks_t is different. Row count of innodb_t: $innodb_count. Row count of myrocks_t: $myrocks_count"
            exit 1
        else
            echo "Row count of both tables innodb_t and myrocks_t is same after restore: Pass"
        fi

        echo "Check the checksum of tables innodb_t and myrocks_t after restore"
        innodb_checksum=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.innodb_t;"|awk '{print $2}')
        myrocks_checksum=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.myrocks_t;"|awk '{print $2}')
        if [ "$innodb_checksum" -ne "$myrocks_checksum" ]; then
            echo "ERR: The checksum of tables innodb_t and myrocks_t is different. Checksum of innodb_t: $innodb_checksum. Checksum of myrocks_t: $myrocks_checksum"
            exit 1
        else
            echo "Checksum of both tables innodb_t and myrocks_t is same after restore: Pass"
        fi
    else
        echo "Skipping Test: Backup and Restore when data is added in both innodb and myrocks tables simultaneously, as rocksdb is disabled"
    fi
}

test_update_truncate_table() {
    # This test suite takes an incremental backup during update and truncate of tables

    echo "Test: Backup and Restore during update and truncate of a table"

    update_truncate_table

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

test_create_drop_database() {
    # This test suite takes an incremental backup during create and drop of a database

    if [ $VERSION -lt 080000 ] ; then
        echo "Skipping Test: Backup and Restore during create and drop of a database, for PS/MS-${VER} as this scenario is not supported"
        return
    fi

    echo "Test: Backup and Restore during create and drop of a database"

    create_drop_database

    incremental_backup "--lock-ddl"
}

test_compressed_column() {
    # This test suite takes an incremental backup during column compression

    echo "Test: Backup and Restore during column compression"
    compressed_column

    incremental_backup
}

test_compression_dictionary() {
    # This test suite takes an incremental backup during column compression using compression dictionary

    echo "Test: Backup and Restore during column compression using compression dictionary"

    compression_dictionary
    if [ "$?" -ne 0 ]; then
        return
    fi

    incremental_backup
}

test_partitioned_tables() {
    # This test suite takes an incremental backup for partitioned tables

    echo "Test: Backup and Restore during creation of partitioned tables"

    partitioned_tables

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

test_add_drop_column_instant() {
    # This test suite takes an incremental backup when a column is added or dropped using instant algorithm

    if [ $VERSION -lt 080000 ]; then
        echo "Skipping Test: Backup and Restore during add and drop column as the instant algorithm is not supported in MS/PS-${VER}"
        return
    fi

    echo "Test: Backup and Restore during column add and drop using instant algorithm"

    add_drop_column_instant
    sleep 2

    incremental_backup
}

test_add_drop_column_algorithms() {
    # This test suite takes an incremental backup when a column is added or dropped using different algorithms

    echo "Test: Backup and Restore during column add and drop using different algorithms"

    add_drop_column_algorithms
    sleep 2

    incremental_backup
}

test_run_all_statements() {
    # This test suite runs the statements for all previous tests simultaneously in background

    echo "Test: Backup and Restore during various tests running simultaneously"
    # Change storage engine does not work due to PS-5559 issue
    #change_storage_engine

    add_drop_index

    add_drop_tablespace

    change_compression

    change_row_format

    update_truncate_table

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

test_inc_backup_encryption_8_0() {
    # This test suite takes an incremental backup when PS 8.0 is running with encryption
    local encrypt_type="$1"
    rocksdb="disabled" # Rocksdb tables cannot be created when encryption is enabled

    # Note: Binlog cannot be applied to backup if it is encrypted

    if [ "${encrypt_type}" = "keyring_file_plugin" ]; then
        if [ "$server_type" == "MS" ]; then
            server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
        else
            server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
        fi

        echo "#################################################################################################################"
        echo "# Test Suite1: Incremental Backup and Restore for ${server_type}-${VER} using PXB-${PXB_VER} with $encrypt_type encryption #"
        echo "#################################################################################################################"
        suite=1

        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring"
        else
            pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        echo "Test1.1: Incremental Backup and Restore with basic $encrypt_type encryption options"

        initialize_db "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --default-table-encryption=ON"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --default-table-encryption=ON"

        echo "====================================================================================="

        echo "Test1.2: Incremental Backup and Restore for ${server_type}-${VER} running with all encryption options enabled"

        initialize_db "${server_options} --binlog-encryption"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options} --binlog-encryption"

        echo "====================================================================================="

        echo "Test1.3: Incremental Backup and Restore for ${server_type}-${VER} using transition-key and generate-new-master-key"

        if [ "${install_type}" = "package" ]; then
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_file.so" "${server_options} --binlog-encryption"
        else
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_file.so" "${server_options} --binlog-encryption"
        fi

        echo "====================================================================================="

        echo "Test1.4: Incremental Backup and Restore for ${server_type}-${VER} using generate-transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options}" "${pxb_encrypt_options} --generate-new-master-key --early-plugin-load=keyring_file.so" "${server_options} --binlog-encryption"

        echo "====================================================================================="

        echo "Test1.5: Incremental Backup and Restore with lz4 compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "====================================================================================="

        echo "Test1.6: Incremental Backup and Restore with zstd compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "====================================================================================="

        echo "Test1.7: Various test suites: binlog-encryption is not included so that binlog can be applied"

        lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}"'

    elif [ "${encrypt_type}" = "keyring_vault_plugin" ]; then
        if [ "$server_type" == "MS" ]; then
            echo "[SKIPPED] Test Suite$suite: MS 8.0 does not support $encrypt_type for encryption"
            return
        elif [ $VERSION -ge 080100 ]; then
            echo "[SKIPPED] Test Suite2: $encrypt_type is not supported in PS-${VER}"
            return
        else
            start_vault_server
        fi

        # Run keyring_vault tests for PS8.0
        server_options="--early-plugin-load=keyring_vault=keyring_vault.so --keyring_vault_config=${vault_config} --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"

        echo "################################################################################################################"
        echo "# Test Suite2: Incremental Backup and Restore for PS-${VER} using PXB-${PXB_VER} with $encrypt_type encryption #"
        echo "################################################################################################################"
        suite=2

        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options="--keyring_vault_config=${vault_config}"
        else
            pxb_encrypt_options="--keyring_vault_config=${vault_config} --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        echo "Test2.1: Incremental Backup and Restore with basic $encrypt_type encryption options"

        initialize_db "--early-plugin-load=keyring_vault=keyring_vault.so --keyring_vault_config=${vault_config} --default-table-encryption=ON"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "--early-plugin-load=keyring_vault=keyring_vault.so --keyring_vault_config=${vault_config} --default-table-encryption=ON"

        echo "====================================================================================="

        echo "Test2.2: Incremental Backup and Restore for PS-${VER} running with all encryption options enabled"
        initialize_db "${server_options} --binlog-encryption"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options} --binlog-encryption"

        echo "====================================================================================="

        echo "Test2.3: Incremental Backup and Restore for PS-${VER} using transition-key and generate-new-master-key"

        if [ "${install_type}" = "package" ]; then
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_vault.so" "${server_options} --binlog-encryption"
        else
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_vault.so" "${server_options} --binlog-encryption"
        fi

        echo "====================================================================================="

        echo "Test2.4: Incremental Backup and Restore for PS-${VER} using generate-transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options}" "${pxb_encrypt_options} --generate-new-master-key --early-plugin-load=keyring_vault.so" "${server_options} --binlog-encryption"

        echo "====================================================================================="

        echo "Test2.5: Incremental Backup and Restore with lz4 compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "====================================================================================="

        echo "Test2.6: Incremental Backup and Restore with zstd compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "====================================================================================="

        echo "Test2.7: Various test suites: binlog-encryption is not included so that binlog can be applied"

        lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}"'

    elif [ "${encrypt_type}" = "keyring_vault_component" ]; then

        if [ "$server_type" == "MS" ]; then
            server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
        else
            server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
        fi
        if [ $VERSION -lt 080100 ]; then
            echo "[SKIPPED] Test Suite3: $encrypt_type is not supported in ${server_type}-${VER}"
            return
        else
            start_vault_server
        fi

        echo "####################################################################################################################"
        echo "# Test Suite3: Incremental Backup and Restore for ${server_type}-${VER} using PXB-${PXB_VER} with $encrypt_type encryption #"
        echo "####################################################################################################################"
        suite=3

        echo "Create global manifest file"
        cat <<EOF >"${mysqldir}"/bin/mysqld.my
{
    "components": "file://component_keyring_vault"
}
EOF
        if [[ ! -f "${mysqldir}"/bin/mysqld.my ]]; then
            echo "ERR: The global manifest could not be created in ${mysqldir}/bin/mysqld.my"
            exit 1
        fi

        echo "Create global configuration file"
        cat <<EOF >"${mysqldir}"/lib/plugin/component_keyring_vault.cnf
{
"vault_url": "$vault_url",
"secret_mount_point": "$secret_mount_point",
"token": "$token",
"vault_ca": "$vault_ca"
}
EOF
        if [[ ! -f "${mysqldir}"/lib/plugin/component_keyring_vault.cnf ]]; then
            echo "ERR: The global configuration could not be created in ${mysqldir}/lib/plugin/component_keyring_vault.cnf"
            exit 1
        fi

        echo "Test3.1: Incremental Backup and Restore with basic $encrypt_type encryption options"
        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options=""
        else
            pxb_encrypt_options="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        pxb_component_config="--component-keyring-config=${mysqldir}/lib/plugin/component_keyring_vault.cnf"

        initialize_db "--default-table-encryption=ON"
        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "--default-table-encryption=ON"

        echo "====================================================================================="

        echo "Test3.2: Incremental Backup and Restore for ${server_type}-${VER} running with all encryption options enabled"

        initialize_db "${server_options} --binlog-encryption"

        # The --keyring_file_data option is not required to backup/prepare/restore in component by default, but it can be included if it is different than the mysql config
        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options} --binlog-encryption"

        echo "====================================================================================="

        echo "Test3.3: Incremental Backup and Restore for ${server_type} using transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} ${pxb_component_config}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key ${pxb_component_config}" "${server_options} --binlog-encryption"

        echo "====================================================================================="

         echo "Test3.4: Incremental Backup and Restore for ${server_type} using generate-transition-key and generate-new-master-key"

         incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options} ${pxb_component_config} --generate-new-master-key" "${server_options} --binlog-encryption"

        echo "====================================================================================="

         echo "Test3.5: Incremental Backup and Restore with lz4 compression, encryption and streaming"

         incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "====================================================================================="

         echo "Test3.6: Incremental Backup and Restore with zstd compression, encryption and streaming"

         incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "====================================================================================="

         echo "3.7:Various test suites: binlog-encryption is not included so that binlog can be applied"

         lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}"'

    elif [ "${encrypt_type}" = "keyring_file_component" ]; then
        if [ $VERSION -ge 080000 ]; then
          if [ "$server_type" == "MS" ]; then
             server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
          else
             server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
          fi
        else
            echo "[SKIPPED] Test Suite4: $encrypt_type is not supported on PS/MS-${VER}"
            return
        fi

        echo "############################################################################################################################"
        echo "# Test Suite4: Incremental Backup and Restore for ${server_type}-${VER} using PXB-${PXB_VER} with $encrypt_type encryption #"
        echo "############################################################################################################################"
        suite=4

        echo "Create global manifest file"
        cat <<EOF >"${mysqldir}"/bin/mysqld.my
{
    "components": "file://component_keyring_file"
}
EOF
        if [[ ! -f "${mysqldir}"/bin/mysqld.my ]]; then
            echo "ERR: The global manifest could not be created in ${mysqldir}/bin/mysqld.my"
            exit 1
        fi
        #chmod ugo=+r "${mysqldir}"/bin/mysqld.my

        echo "Create global configuration file"
        cat <<EOF >"${mysqldir}"/lib/plugin/component_keyring_file.cnf
{
    "path": "$mysqldir/lib/plugin/component_keyring_file",
    "read_only": true
}
EOF
        if [[ ! -f "${mysqldir}"/lib/plugin/component_keyring_file.cnf ]]; then
            echo "ERR: The global configuration could not be created in ${mysqldir}/lib/plugin/component_keyring_file.cnf"
            exit 1
        fi

        echo "Test4.1: Incremental Backup and Restore with basic $encrypt_type encryption options"
        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options=""
        else
            pxb_encrypt_options="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        pxb_component_config="--component-keyring-config=${mysqldir}/lib/plugin/component_keyring_file.cnf"

        initialize_db "--default-table-encryption=ON"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "--default-table-encryption=ON"

        echo "###################################################################################"

        echo "Test4.2: Incremental Backup and Restore for ${server_type}-${VER} running with all encryption options enabled"

        initialize_db "${server_options} --binlog-encryption"

        # The --keyring_file_data option is not required to backup/prepare/restore in component by default, but it can be included if it is different than the mysql config
        incremental_backup "${pxb_encrypt_options} --keyring_file_data=${mysqldir}/lib/plugin/component_keyring_file" "${pxb_encrypt_options} --keyring_file_data=${mysqldir}/lib/plugin/component_keyring_file ${pxb_component_config}" "${pxb_encrypt_options} --keyring_file_data=${mysqldir}/lib/plugin/component_keyring_file" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test4.3: Incremental Backup and Restore for ${server_type} using transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} ${pxb_component_config}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key ${pxb_component_config}" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test4.4: Incremental Backup and Restore for ${server_type} using generate-transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options} ${pxb_component_config} --generate-new-master-key" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test4.5: Incremental Backup and Restore with lz4 compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test4.6: Incremental Backup and Restore with zstd compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test4.7:Various test suites: binlog-encryption is not included so that binlog can be applied"

        lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}"'

    elif [ "${encrypt_type}" = "keyring_kmip_component" ]; then
        if [ "$server_type" == "MS" ]; then
            echo "MS 8.0 does not support keyring kmip for encryption, skipping keyring kmip tests"
            return
        fi

        # Run keyring_kmip tests for PS8.0
        server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"

        echo "Test Suite5: Incremental Backup and Restore for ${server_type}-${VER} using PXB-${PXB_VER} with $encrypt_type encryption"
        suite=5

        echo "Create global manifest file"
        cat <<EOF >"${mysqldir}"/bin/mysqld.my
{
    "components": "file://component_keyring_kmip"
}
EOF
        if [[ ! -f "${mysqldir}"/bin/mysqld.my ]]; then
            echo "ERR: The global manifest could not be created in ${mysqldir}/bin/mysqld.my"
            exit 1
        fi

        echo "Create global configuration file"
        cat <<EOF >"${mysqldir}"/lib/plugin/component_keyring_kmip.cnf
{
    "path": "$mysqldir/keyring_kmip", "server_addr": "$kmip_server_address", "server_port": "$kmip_server_port", "client_ca": "$kmip_client_ca", "client_key": "$kmip_client_key", "server_ca": "$kmip_server_ca"
}
EOF
        if [[ ! -f "${mysqldir}"/lib/plugin/component_keyring_kmip.cnf ]]; then
            echo "ERR: The global configuration could not be created in ${mysqldir}/lib/plugin/component_keyring_kmip.cnf"
            exit 1
        fi

        echo "Test5.1: Incremental Backup and Restore with basic $encrypt_type encryption options"
        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options=""
        else
            pxb_encrypt_options="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        pxb_component_config="--component-keyring-config=${mysqldir}/lib/plugin/component_keyring_kmip.cnf"

        initialize_db "--default-table-encryption=ON"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "--default-table-encryption=ON"

        echo "###################################################################################"

        echo "Test5.2: Incremental Backup and Restore for ${server_type}-${VER} running with all encryption options enabled"

        initialize_db "${server_options} --binlog-encryption"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test5.3: Incremental Backup and Restore for ${server_type} using transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "${pxb_encrypt_options} ${pxb_component_config} --transition-key=${encrypt_key}" "${pxb_encrypt_options} ${pxb_component_config} --transition-key=${encrypt_key} --generate-new-master-key" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test5.4: Incremental Backup and Restore for ${server_type} using generate-transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options} ${pxb_component_config} --generate-new-master-key" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test5.5: Incremental Backup and Restore with lz4 compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test5.6: Incremental Backup and Restore with zstd compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test5.7: Various test suites: binlog-encryption is not included so that binlog can be applied"

        lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}"'

    elif [ "${encrypt_type}" = "keyring_kms_component" ]; then
        if [ "$server_type" == "MS" ]; then
            echo "MS 8.0 does not support keyring kms for encryption, skipping keyring kms tests"
            return
        fi

        # Run keyring_kms tests for PS8.0
        server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"

        echo "Test Suite6: Incremental Backup and Restore for ${server_type}-${VER} using PXB-${PXB_VER} with $encrypt_type encryption"
        suite=6

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

        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options=""
        else
            pxb_encrypt_options="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        pxb_component_config="--component-keyring-config=${mysqldir}/lib/plugin/component_keyring_kms.cnf"

        echo "###################################################################################"

        echo "Test6.1: Incremental Backup and Restore with basic $encrypt_type encryption options"

        initialize_db "--default-table-encryption=ON"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "--default-table-encryption=ON"

        echo "###################################################################################"

        echo "Test6.2: Incremental Backup and Restore for ${server_type}-${VER} running with all encryption options enabled"

        initialize_db "${server_options} --binlog-encryption"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test6.3: Incremental Backup and Restore for ${server_type} using transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "${pxb_encrypt_options} ${pxb_component_config} --transition-key=${encrypt_key}" "${pxb_encrypt_options} ${pxb_component_config} --transition-key=${encrypt_key} --generate-new-master-key" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test6.4: Incremental Backup and Restore for ${server_type} using generate-transition-key and generate-new-master-key"

        incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options} ${pxb_component_config} --generate-new-master-key" "${server_options} --binlog-encryption"

        echo "###################################################################################"

        echo "Test6.5: Incremental Backup and Restore with lz4 compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test6.6: Incremental Backup and Restore with zstd compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test6.7: Various test suites: binlog-encryption is not included so that binlog can be applied"

        lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options} ${pxb_component_config}" "${pxb_encrypt_options}" "${server_options}"'

    else
        echo "[ERROR] Invalid $encrypt_type is not supported in PS/MS-${VER}"
        exit 1
    fi

    # Running test suites with lock ddl backup command
    echo "Test$suite.8: Backup and Restore during add and drop index"
    add_drop_index
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.9: Backup and Restore during add and drop tablespace"
    add_drop_tablespace
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.10: Backup and Restore during change in compression"
    change_compression
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.11: Backup and Restore during change in row format"
    change_row_format
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.12: Backup and Restore during update and truncate of a table"
    update_truncate_table
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.13: Backup and Restore during create and drop of a database"
    create_drop_database
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.14: Backup and Restore during rename index"
    rename_index
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.15: Backup and Restore during add and drop full text index"
    add_drop_full_text_index
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.16: Backup and Restore during index type change"
    change_index_type
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.17: Backup and Restore during add and drop spatial index"
    add_drop_spatial_index
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.18: Backup and Restore during add and delete of an encrypted table"
    create_delete_encrypted_table
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.19: Backup and Restore for partitioned tables"
    partitioned_tables
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.20: Backup and Restore during column compression"
    compressed_column
    eval $lock_ddl_cmd
    echo "========================================================================================="

    echo "Test$suite.21: Backup and Restore during column compression using compression dictionary"
    if compression_dictionary; then
        eval $lock_ddl_cmd
    fi
    echo "========================================================================================="

    echo "Test$suite.22: Backup and Restore during encryption change"
    change_encryption
    eval $lock_ddl_cmd

    # Remove keyring component configuration so that test suites after this test suite can run without encryption
    if [[ -f "${mysqldir}"/bin/mysqld.my ]]; then
        rm "${mysqldir}"/bin/mysqld.my
    fi

    if [[ -f "${mysqldir}"/lib/plugin/component_keyring_file.cnf ]]; then
        rm "${mysqldir}"/lib/plugin/component_keyring_file.cnf
    fi

    if [[ -f "${mysqldir}"/lib/plugin/component_keyring_kmip.cnf ]]; then
        rm "${mysqldir}"/lib/plugin/component_keyring_kmip.cnf
    fi

    if [[ -f "${mysqldir}"/lib/plugin/component_keyring_kms.cnf ]]; then
        rm "${mysqldir}"/lib/plugin/component_keyring_kms.cnf
    fi

    echo "###################################################################################"
    echo "All tests in suite:$suite for $encrypt_type executed OK!"
    echo "###################################################################################"
}

test_inc_backup_encryption_2_4() {
    # This test suite takes an incremental backup when PS5.7 is running with encryption
    local encrypt_type="$1"
    local server_type="$2"
    rocksdb="disabled" # Rocksdb tables cannot be created when encryption is enabled

    # Note: Binlog cannot be applied to backup if it is encrypted

    if [ "${encrypt_type}" = "keyring_file_plugin" ]; then
        if [ "${server_type}" = "MS" ]; then
            server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"
        else
            server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-tmp-files --innodb-temp-tablespace-encrypt --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-binlog"
        fi

        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring"
        else
            pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        echo "Test Suite1: Incremental Backup and Restore for ${server_type}5.7 using PXB-${PXB_VER} with keyring_file encryption"
        suite=1

        # PXB 2.4 does not support redo log and undo log encryption
        echo "Test: Incremental Backup and Restore when all encryption options are enabled in ${server_type}5.7"

        initialize_db "${server_options}"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}"

        echo "###################################################################################"

        echo "Test1.1: Incremental Backup and Restore for ${server_type} using transition-key and generate-new-master-key"

        if [ "${install_type}" = "package" ]; then
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_file.so" "${server_options}"
        else
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_file.so" "${server_options}"
        fi

        echo "###################################################################################"

        # Test commented due to PXB-2158
        echo "[DISABLED]Test1.2: Incremental Backup and Restore for ${server_type} using generate-transition-key and generate-new-master-key"

        #incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options}" "${pxb_encrypt_options} --generate-new-master-key --early-plugin-load=keyring_file.so" "${server_options}"

        #echo "###################################################################################"

        echo "Test1.3: Incremental Backup and Restore with quicklz compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "stream" ""

        echo "###################################################################################"

        echo "Test1.4: Various tests: binlog-encryption is not included so that binlog can be applied"
        if [ "${server_type}" = "MS" ]; then
            lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl-per-table" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}"'
        else
            initialize_db "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-tmp-files --innodb-temp-tablespace-encrypt --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"

            lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-tmp-files --innodb-temp-tablespace-encrypt --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"'
        fi

    elif [ "${encrypt_type}" = "keyring_vault_plugin" ]; then

        if [ "${server_type}" = "MS" ]; then
            echo "MS 5.7 does not support keyring vault for encryption, skipping keyring vault tests"
            return
        else
            start_vault_server
        fi

        echo "Test Suite1: Incremental Backup and Restore for PS-${VER} using PXB-${PXB_VER} with $encrypt_type encryption"
        suite=1

        # PXB 2.4 does not support redo log and undo log encryption
        echo "Test1.1: Incremental Backup and Restore when all encryption options are enabled in PS-${VER}"

        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options="--keyring_vault_config=${vault_config}"
        else
            pxb_encrypt_options="--keyring_vault_config=${vault_config} --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        server_options="--early-plugin-load=keyring_vault=keyring_vault.so --keyring_vault_config=${vault_config} --innodb-encrypt-tables=ON --encrypt-tmp-files --innodb-temp-tablespace-encrypt --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"

        initialize_db "${server_options} --encrypt-binlog"

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options} --encrypt-binlog"
        echo "###################################################################################"

        echo "Test1.2: Incremental Backup and Restore for ${server_type} using transition-key and generate-new-master-key"

        if [ "${install_type}" = "package" ]; then
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_vault.so" "${server_options} --encrypt-binlog"
        else
            incremental_backup "${pxb_encrypt_options} --transition-key=${encrypt_key}" "--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --transition-key=${encrypt_key}" "${pxb_encrypt_options} --transition-key=${encrypt_key} --generate-new-master-key --early-plugin-load=keyring_vault.so" "${server_options} --encrypt-binlog"
        fi

        echo "###################################################################################"

        # Test commented due to PXB-2158
        echo "[DISABLED]Test1.3: Incremental Backup and Restore for ${server_type} using generate-transition-key and generate-new-master-key"

        #incremental_backup "${pxb_encrypt_options} --generate-transition-key" "${pxb_encrypt_options}" "${pxb_encrypt_options} --generate-new-master-key --early-plugin-load=keyring_vault.so" "${server_options} --encrypt-binlog"

        #echo "###################################################################################"

        echo "Test1.4: Incremental Backup and Restore with quicklz compression, encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options} --encrypt-binlog" "stream" ""

        echo "###################################################################################"

        echo "Test1.5: Various tests: binlog-encryption is not included so that binlog can be applied"

        initialize_db "${server_options}"

        lock_ddl_cmd='incremental_backup "${pxb_encrypt_options} --lock-ddl" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}"'
    fi

    # Running test suites with lock ddl backup command

    echo "Test: Backup and Restore during add and drop index"
    add_drop_index
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during add and drop tablespace"
    add_drop_tablespace
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during change in compression"
    change_compression
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during change in row format"
    change_row_format
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during update and truncate of a table"
    update_truncate_table
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during rename index"
    rename_index
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during add and drop full text index"
    add_drop_full_text_index
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during index type change"
    change_index_type
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during add and delete of an encrypted table"
    create_delete_encrypted_table
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during creation of partitioned tables"
    partitioned_tables
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during column compression"
    compressed_column
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during column compression using compression dictionary"
    compression_dictionary
    eval $lock_ddl_cmd
    echo "###################################################################################"

    echo "Test: Backup and Restore during encryption change"
    change_encryption
    eval $lock_ddl_cmd
}

test_streaming_backup() {
    # This test suite tests incremental backup when it is streamed

    echo "Test: Incremental Backup and Restore with streaming"

    initialize_db

    incremental_backup "" "" "" "--log-bin=binlog" "stream" ""

    if [ $VERSION -lt 080000 ]; then

        echo "###################################################################################"

        echo "Test: Incremental Backup and Restore with streaming format as tar"

        incremental_backup "" "" "" "--log-bin=binlog" "tar" ""
    fi
}

test_compress_stream_backup() {
    # This test suite tests incremental backup when it is compressed and streamed

    echo "###################################################################################"

    # Skip lz4 and zstd compression tests in PXB2.4 and PS/MS 5.7
    if [ $VERSION -lt 080000 ]; then
        return
    fi

    echo "Test: Incremental Backup and Restore with lz4 compression and streaming"

    incremental_backup "--compress=lz4 --compress-threads=10" "" "" "--log-bin=binlog" "stream" ""

    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with zstd compression and streaming"

    incremental_backup "--compress=zstd --compress-threads=10" "" "" "--log-bin=binlog" "stream" ""
}

test_encrypt_compress_stream_backup() {
    # This test suite tests incremental backup when it is encrypted, compressed and streamed

    echo "###################################################################################"

    # Skip lz4 and zstd compression tests in PXB2.4 and PS/MS 5.7
    if [ $VERSION -lt 080000 ]; then
        return
    fi

    echo "Test: Incremental Backup and Restore with lz4 compression, encryption and streaming"

    incremental_backup "--encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "" "" "--log-bin=binlog" "stream" ""

    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with zstd compression, encryption and streaming"

    incremental_backup "--encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "" "" "--log-bin=binlog" "stream" ""
}

test_compress_backup() {
    # This test suite tests incremental backup when it is compressed

    echo "Test Suite: Incremental Backup and Restore with compression"

    # Skip lz4 and zstd compression tests in PXB2.4 and PS/MS 5.7
    if [ $VERSION -lt 080000 ]; then
        return
    fi

    echo "Test: Lz4 compression"
    incremental_backup "--compress=lz4" "" "" "--log-bin=binlog" "" ""
    echo "###################################################################################"

    echo "Test: Lz4 compression with --compress-threads=10 --parallel=10"
    incremental_backup "--compress=lz4 --compress-threads=10 --parallel=10" "" "" "--log-bin=binlog" "" ""
    echo "###################################################################################"

    echo "Test: Lz4 compression with --compress-chunk-size=4096K --compress-threads=100 --parallel=100"
    incremental_backup "--compress=lz4 --compress-chunk-size=4096K --compress-threads=100 --parallel=100" "" "" "--log-bin=binlog" "" ""
    echo "###################################################################################"

    echo "Test: Zstd compression"
    incremental_backup "--compress=zstd" "" "" "--log-bin=binlog" "" ""
    echo "###################################################################################"

    echo "Test: Zstd compression with --compress-threads=10 --parallel=10"
    incremental_backup "--compress=zstd --compress-threads=10 --parallel=10" "" "" "--log-bin=binlog" "" ""
    echo "###################################################################################"

    echo "Test: Zstd compression with --compress-chunk-size=4096K --compress-threads=100 --parallel=100"
    incremental_backup "--compress=zstd --compress-chunk-size=4096K --compress-threads=100 --parallel=100" "" "" "--log-bin=binlog" "" ""
    echo "###################################################################################"

    echo "Test: Zstd compression with --compress-chunk-size=4096K --compress-threads=100 --parallel=100 --compress-zstd-level=19"
    incremental_backup "--compress=zstd --compress-chunk-size=4096K --compress-threads=100 --parallel=100 --compress-zstd-level=19" "" "" "--log-bin=binlog" "" ""
}

test_cloud_inc_backup() {
    # This test suite tests incremental backup for cloud and requires the cloud options in a config file

    echo "Test Suite: Cloud Tests"
    initialize_db

    echo "Test: Incremental Backup and Restore with cloud"
    incremental_backup "--parallel=10" "" "" "" "cloud" "--defaults-file=${cloud_config} --verbose"
    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with encryption and streaming"
    incremental_backup "--encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K" "" "" "" "cloud" "--defaults-file=${cloud_config} --verbose"
    echo "###################################################################################"
                
    # Run encryption tests for MS/PS 5.7

    if [ $VERSION -lt 080000 ]; then
        echo "Test: Incremental Backup and Restore for MS/PS-${VER} with keyring_file encryption"

        server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"

        initialize_db "${server_options}"

        if [ "${install_type}" = "package" ]; then
            pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring"
        else
            pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
        fi

        incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "cloud" "--defaults-file=${cloud_config} --verbose"

        echo "###################################################################################"

        echo "Test: Incremental Backup and Restore for MS/PS-${VER} with keyring_file encryption, quicklz compression, file encryption and streaming"

        incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "cloud" "--defaults-file=${cloud_config} --verbose"

        return
    fi

    echo "Test: Incremental Backup and Restore with lz4 compression, encryption and streaming"
    incremental_backup "--encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "" "" "" "cloud" "--defaults-file=${cloud_config} --verbose"
    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with zstd compression, encryption and streaming"
    incremental_backup "--encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "" "" "" "cloud" "--defaults-file=${cloud_config} --verbose"
    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore for MS/PS-${VER} with keyring_file encryption"
    rocksdb_status="${rocksdb}"
    rocksdb="disabled" # Rocksdb tables cannot be created when encryption is enabled
    server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"

    initialize_db "${server_options}"

    if [ "${install_type}" = "package" ]; then
        pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring"
    else
        pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
    fi

    incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "cloud" "--defaults-file=${cloud_config} --verbose"

    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore for MS/PS-${VER} with keyring_file encryption, lz4 compression, file encryption and streaming"

    incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=lz4 --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "cloud" "--defaults-file=${cloud_config} --verbose"

    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore for MS/PS 8.0 with keyring_file encryption, zstd compression, file encryption and streaming"

    incremental_backup "${pxb_encrypt_options} --encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress=zstd --compress-threads=10" "${pxb_encrypt_options}" "${pxb_encrypt_options}" "${server_options}" "cloud" "--defaults-file=${cloud_config} --verbose"

    rocksdb="${rocksdb_status}"
}

test_ssl_backup() {
    # This test suite tests incremental backup with ssl options
    backup_user="backup"

    echo "Test: Incremental Backup and Restore with ssl options"

    initialize_db

    echo "Test: Backup with SSL certificates and keys"

    # Restart server with ssl options
    restart_db "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem"

    # Add user with ssl
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE USER 'backup'@'localhost' REQUIRE SSL;"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "GRANT ALL ON *.* TO 'backup'@'localhost';"

    incremental_backup "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem" "" "" "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem" "" ""
    echo "###################################################################################"

    echo "Test: Backup with SSL option --ssl-mode"
    mysql_port=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "select @@port;")

    incremental_backup "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem --ssl-mode=REQUIRED --host=127.0.0.1 -P ${mysql_port}" "" "" "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem" "" ""

    echo "###################################################################################"

    echo "Test: Backup with SSL option --ssl-cipher and --ssl-fips-mode"
    # Note: PS should be compiled with OpenSSL lib to use with --ssl-fips-mode
    # Restart server with ssl-cipher and ssl-fips-mode options
    restart_db "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem --ssl-cipher=DHE-RSA-AES128-GCM-SHA256:AES128-SHA --ssl-fips-mode=ON"

    incremental_backup "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem --ssl-cipher=AES128-SHA --ssl-fips-mode=ON --host=127.0.0.1 -P ${mysql_port}" "" "" "--ssl-ca=${mysqldir}/data/ca.pem --ssl-cert=${mysqldir}/data/server-cert.pem --ssl-key=${mysqldir}/data/server-key.pem --ssl-cipher=DHE-RSA-AES128-GCM-SHA256:AES128-SHA --ssl-fips-mode=ON" "" ""

    backup_user="root"
}

test_inc_backup_archive_log() {
    # This test suite takes an incremental backup with redo archive log and innodb params

    if [ $VERSION -lt 080000 ]; then
        echo "Skipping redo archive log tests for PS/MS-${VER} as these scenarios are not supported"
        return
    fi

    if [ ! -d ${mysqldir}/archive ]; then
        mkdir -m 744 ${mysqldir}/archive
    fi

    echo "Test: Incremental Backup and Restore with --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs"

    initialize_db "--innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive"

    incremental_backup "" "" "" "--innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive" "" ""
    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with --innodb-redo-log-capacity=536870912 --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs"

    initialize_db "--innodb-redo-log-capacity=536870912 --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive"

    incremental_backup "" "--innodb-log-file-size=536870912" "" "--innodb-redo-log-capacity=536870912 --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive" "" ""
    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with --innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs"

    initialize_db "--innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive"

    incremental_backup "--innodb-log-file-size=2147483648" "--innodb-log-file-size=2147483648" "--innodb-redo-log-capacity=2147483648" "--innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive" "" ""
    echo "###################################################################################"

    echo "Test: Incremental Backup and Restore with --innodb-redo-log-capacity=536870912 --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs and encryption options"

    server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --innodb-extend-and-initialize=OFF"

    initialize_db "${server_options} --binlog-encryption --innodb-redo-log-capacity=536870912 --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive"

    if [ "${install_type}" = "package" ]; then
        pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring"
    else
        pxb_encrypt_options="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"
    fi

    incremental_backup "${pxb_encrypt_options}" "${pxb_encrypt_options} --innodb-log-file-size=536870912" "${pxb_encrypt_options}" "${server_options} --binlog-encryption --innodb-redo-log-capacity=536870912 --binlog-transaction-compression=ON --binlog-transaction-compression-level-zstd=22 --innodb-extend-and-initialize=OFF --innodb-log-writer-threads=OFF --innodb-redo-log-archive-dirs=archive:${mysqldir}/archive" "" ""
}

test_grant_tables() {
    # This test suite takes an incremental backup when a user is created and dropped

    echo "Test: Backup and Restore during creation and dropping of a user"

    if [ "${rocksdb}" = "enabled" ]; then
        mysql_options="--log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"
    else
        mysql_options="--binlog-format=mixed"
    fi
    
    initialize_db "${mysql_options}"

    grant_tables

    incremental_backup "" "" "" "${mysql_options}" "" ""
}

test_inc_backup_innodb_params() {
    # This test suite takes a full backup, incremental backup with different innodb parameter values

    echo "Test: Backup and Restore with --innodb-redo-log-capacity=209715200"

    initialize_db "--innodb-redo-log-capacity=209715200"

    incremental_backup "--innodb-log-file-size=209715200" "--innodb-log-file-size=209715200" "--innodb-redo-log-capacity=209715200" "--innodb-redo-log-capacity=209715200" "" ""

    echo "###################################################################################"

    echo "Test: Backup and Restore with --innodb-redo-log-capacity=2147483648 "

    initialize_db "--innodb-redo-log-capacity=2147483648"

    incremental_backup "--innodb-log-file-size=2147483648" "--innodb-log-file-size=2147483648" "--innodb-redo-log-capacity=2147483648" "--innodb-redo-log-capacity=2147483648" "" ""

    echo "###################################################################################"

    echo "Test: Backup and Restore with --innodb-redo-log-capacity=8388608 --innodb-buffer-pool-size=2G"

    initialize_db "--innodb-redo-log-capacity=8388608 --innodb-buffer-pool-size=2G"

    incremental_backup "--innodb-log-file-size=8388608 --innodb-buffer-pool-size=2G" "--innodb-log-file-size=8388608 --innodb-buffer-pool-size=2G" "--innodb-redo-log-capacity=8388608 --innodb-buffer-pool-size=2G" "--innodb-redo-log-capacity=8388608 --innodb-buffer-pool-size=2G" "" ""

    echo "###################################################################################"

    echo "Test: Backup and Restore with --innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G"

    initialize_db "--innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G"

    incremental_backup "--innodb-log-file-size=2147483648 --innodb-buffer-pool-size=2G" "--innodb-log-file-size=2147483648 --innodb-buffer-pool-size=2G" "--innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G" "--innodb-redo-log-capacity=2147483648 --innodb-buffer-pool-size=2G" "" ""

    echo "###################################################################################"

    echo "Test: Backup and Restore with --skip-log-bin"

    # Note: This test might produce differences between original and restored data since binlog cannot be applied after restore

    initialize_db "--skip-log-bin"

    incremental_backup "" "" "" "--skip-log-bin" "" ""

    echo "###################################################################################"

    echo "Test: Backup and Restore with binary logs using absolute path"

    initialize_db "--log-bin=${mysqldir}/data/binlog --log-bin-index=${mysqldir}/data/binlog.index"

    incremental_backup "" "" "" "--log-bin=${mysqldir}/data/binlog --log-bin-index=${mysqldir}/data/binlog.index" "" ""

    echo "###################################################################################"

    echo "Test: Backup and Restore with binary logs in a different location than data directory"

    if [ $VERSION -lt 080000 ]; then
        echo "Skipping test as it will not work in PXB 2.4, due to the defect PXB-2536"
        return
    fi

    mkdir "${mysqldir}"/binlog

    initialize_db "--log-bin=${mysqldir}/binlog/mysql-bin --log-bin-index=${mysqldir}/binlog/mysql-bin.index"

    incremental_backup "" "" "--log-bin=${mysqldir}/binlog/mysql-bin --log-bin-index=${mysqldir}/binlog/mysql-bin.index" "--log-bin=${mysqldir}/binlog/mysql-bin --log-bin-index=${mysqldir}/binlog/mysql-bin.index" "" ""

    # The below test fails, there is an existing PXB issue filed

    #echo "###################################################################################"

    #echo "Test: Backup and Restore with --log-bin=mysql_binlog --log-bin-index=binlog_index.file"

    #initialize_db "--log-bin=mysql_binlog --log-bin-index=binlog_index.file"

    #incremental_backup "--log-bin=mysql_binlog --log-bin-index=binlog_index.file" "--log-bin=mysql_binlog --log-bin-index=binlog_index.file" "--log-bin=mysql_binlog --log-bin-index=binlog_index.file" "--log-bin=mysql_binlog --log-bin-index=binlog_index.file" "" ""

}

test_invisible_column() {
    # This test suite takes an incremental backup when an invisible column is added/dropped

    if [ $VERSION -lt 080000 ]; then
        echo "Skipping Test: Backup and Restore during add and drop of an invisible column for PS/MS-${VER} as this scenario is not supported"
        return
    fi

    echo "Test: Backup and Restore during add and drop of an invisible column"

    add_drop_invisible_column

    incremental_backup "--lock-ddl"
}

test_blob_column() {
    # This test suite takes an incremental backup when a blob column is added/dropped

    echo "Test: Backup and Restore during add and drop of a blob column"

    add_drop_blob_column

    if ${mysqldir}/bin/mysqld --version | grep "5.7" >/dev/null 2>&1 ; then
        if [ "$server_type" == "MS" ]; then
            incremental_backup "--lock-ddl-per-table"
        else
            incremental_backup "--lock-ddl"
        fi
    fi
}

if [ "$#" -lt 1 ]; then
    echo "This script tests backup for innodb and myrocks tables"
    echo "Assumption: PS and PXB are already installed as tarballs"
    echo "Usage: "
    echo "1. Set paths in this script for"
    echo "   xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir, vault_config, cloud_config"
    echo "2. Set config variables in the script for"
    echo "   sysbench, stream, encryption key, kmip, kms"
    echo "3. Run the script as: $0 <Test Suites>"
    echo "   Test Suites: "
    echo "   Various_ddl_tests"
    echo "   File_encrypt_compress_stream_tests"
    echo "   Encryption_PXB2_4_PS5_7_tests"
    echo "   Encryption_PXB2_4_MS5_7_tests"
    echo "   Encryption_PXB8_0_PS8_0_tests"
    echo "   Encryption_PXB8_0_PS8_0_KMIP_tests"
    echo "   Encryption_PXB8_0_PS8_0_KMS_tests"
    echo "   Encryption_PXB8_0_MS8_0_tests"
    echo "   Cloud_backup_tests"
    echo "   Innodb_params_redo_archive_tests"
    echo "   SSL_tests"
    echo " "
    echo "   Example:"
    echo "   $0 Various_ddl_tests File_encrypt_compress_stream_tests Encryption_PXB8_0_PS8_0_tests"
    echo " "
    echo "4. Logs are available at: $logdir"
    exit 1
fi

echo "Running Tests"
find_server_type

for tsuitelist in $*; do
    case "${tsuitelist}" in
        Various_ddl_tests)
            echo "Various test suites"
            # Disabled test test_grant_tables because of Bug https://jira.percona.com/browse/PS-8950
            for testsuite in test_inc_backup test_add_drop_index test_rename_index test_add_drop_full_text_index test_change_index_type test_spatial_data_index test_add_drop_tablespace test_change_compression test_change_row_format test_copy_data_across_engine test_add_data_across_engine test_update_truncate_table test_create_drop_database test_partitioned_tables test_compressed_column test_compression_dictionary test_invisible_column test_blob_column test_add_drop_column_instant test_add_drop_column_algorithms test_run_all_statements; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        File_encrypt_compress_stream_tests)
            echo "File encryption, compression and streaming test suites"
            for testsuite in test_streaming_backup test_compress_stream_backup test_encrypt_compress_stream_backup test_compress_backup; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Encryption_PXB2_4_PS5_7_tests)
            echo "Encryption test suites for PXB-${PXB_VER} and PS-${VER}"
            for testsuite in "test_inc_backup_encryption_2_4 keyring_file_plugin PS" "test_inc_backup_encryption_2_4 keyring_vault_plugin PS"; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Encryption_PXB2_4_MS5_7_tests)
            echo "Encryption_PXB-${PXB_VER} MS-${VER} tests"
            for testsuite in "test_inc_backup_encryption_2_4 keyring_file MS"; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Encryption_PXB8_0_PS8_0_tests)
            echo "Encryption test suites for PXB-${PXB_VER} and PS-${VER}"
            for testsuite in "test_inc_backup_encryption_8_0 keyring_file_plugin" "test_inc_backup_encryption_8_0 keyring_vault_plugin" "test_inc_backup_encryption_8_0 keyring_vault_component" "test_inc_backup_encryption_8_0 keyring_file_component"; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Encryption_PXB8_0_PS8_0_KMIP_tests)
            echo "Encryption test suites for PXB-${PXB_VER} and PS--${VER} using KMIP"
            for testsuite in "test_inc_backup_encryption_8_0 keyring_kmip_component"; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Encryption_PXB8_0_PS8_0_KMS_tests)
            echo "Encryption test suites for PXB-${PXB_VER} and PS-${VER} using KMS"
            for testsuite in "test_inc_backup_encryption_8_0 keyring_kms_component"; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Encryption_PXB8_0_MS8_0_tests)
            echo "Encryption test suites for PXB-${PXB_VER} and MS-${VER}"
            for testsuite in "test_inc_backup_encryption_8_0 keyring_file_plugin" "test_inc_backup_encryption_8_0 keyring_file_component"; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Cloud_backup_tests)
            echo "Cloud backup test suite"
            for testsuite in test_cloud_inc_backup; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        Innodb_params_redo_archive_tests)
            echo "Innodb parameters and redo archive log test suites"
            for testsuite in test_inc_backup_innodb_params test_inc_backup_archive_log; do
                $testsuite
                echo "###################################################################################"
            done
            ;;

        SSL_tests)
            echo "SSL options test suite"
            for testsuite in test_ssl_backup; do
                $testsuite
                echo "###################################################################################"
            done
            ;;
       esac
done
