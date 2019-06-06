#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup for innodb and myrocks tables               #
# Assumption: PS8.0 and PXB8.0 are already installed                   #
# Usage:                                                               #
# 1. Set paths in this script:                                         #
#    xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir, # 
#    vault_config, cloud_config                                        #
# 2. Run the script as: ./innodb_myrocks_backup_tests.sh               #
# 3. Logs are available in: logdir                                     #
########################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb_8_0_6_debug_release/bin"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export mysqldir="$HOME/PS060519_8_0_15_5"
export datadir="$HOME/PS060519_8_0_15_5/data"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"
export vault_config="$HOME/test_mode/vault/keyring_vault.cnf"  # Only required for keyring_vault encryption
export cloud_config="$HOME/minio.cnf"  # Only required for cloud backup tests

# Set sysbench variables
num_tables=10
table_size=1000

# Set stream and encryption key
backup_stream="backup.xbstream"
encrypt_key="mHU3Zs5sRcSB7zBAJP1BInPP5lgShKly"

initialize_db() {
    # This function initializes and starts mysql database
    local MYSQLD_OPTIONS="$1"

    echo "Starting mysql database"
    pushd $mysqldir >/dev/null 2>&1
    if [ ! -f $mysqldir/all_no_cl ]; then
        $qascripts startup.sh
    fi

    ./all_no_cl --log-bin=binlog ${MYSQLD_OPTIONS} >/dev/null 2>&1 
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Please check the directory"
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
    if [[ "${MYSQLD_OPTIONS}" != *"encrypt"* ]]; then
        # Create tables without encryption
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock prepare
    else
        # Create encrypted tables: changed the oltp_common.lua script to include mysql-table-options="Encryption='Y'"
        echo "Creating encrypted tables in innodb"
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --mysql-table-options="Encryption='Y'" prepare
        if [ "$?" -ne 0 ]; then
            for ((i=1; i<=${num_tables}; i++)); do
                echo "Creating the table sbtest$i..."
                ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y';"
            done

            echo "Adding data in tables..."
            sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=30 run >/dev/null 2>&1 
        fi
    fi

    echo "Creating rocksdb data in database"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test_rocksdb;"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock prepare
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
        ${xtrabackup_dir}/xtrabackup --decompress --target-dir=${EXT_DIR} 2>>${logdir}/decompress_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Decompress of backup failed. Please check the log at: ${logdir}/decompress_backup_${log_date}_log"
            exit 1
        else
            echo "Backup was successfully decompressed. Logs available at: ${logdir}/decompress_backup_${log_date}_log"
        fi
    fi
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
            ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --extra-lsndir=${backup_dir} --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream 2>${logdir}/full_backup_${log_date}_log | ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} put full_backup_${log_date} 2>${logdir}/upload_full_backup_${log_date}_log
            ;;

        'stream')
            echo "Taking full backup and creating a stream file"
            ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream --parallel=10 > ${backup_dir}/${backup_stream} 2>${logdir}/full_backup_${log_date}_log
            ;;

        *)
            echo "Taking full backup"
            ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/full_backup_${log_date}_log
            ;;
    esac
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
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
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &

    # Rocksdb data
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &
    sleep 10

    case "${BACKUP_TYPE}" in
        'cloud')
            echo "Taking incremental backup and uploading it"
            ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir} -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream 2>${logdir}/inc_backup_${log_date}_log | ${xtrabackup_dir}/xbcloud ${CLOUD_PARAMS} put inc_backup_${log_date} 2>${logdir}/upload_inc_backup_${log_date}_log
            ;;

        'stream')
            echo "Taking incremental backup and creating a stream file"
            ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} --stream=xbstream --parallel=10 > ${backup_dir}/${backup_stream} 2>${logdir}/inc_backup_${log_date}_log
            ;;

        *)
            echo "Taking incremental backup"
            ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc_backup_${log_date}_log
            ;;
    esac
    if [ "$?" -ne 0 ]; then
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc_backup_${log_date}_log"
        exit 1
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

    # Call function to process backup for streaming, encryption and compression
    process_backup "${BACKUP_TYPE}" "${BACKUP_PARAMS}" "${backup_dir}/inc"

    echo "Preparing full backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --prepare --apply-log-only --target_dir=${backup_dir}/full ${PREPARE_PARAMS} 2>${logdir}/prepare_full_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    echo "Preparing incremental backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc ${PREPARE_PARAMS} 2>${logdir}/prepare_inc_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc_backup_${log_date}_log"
    fi

    echo "Restart mysql server to stop all running queries"
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
    echo "The mysql server was restarted successfully"
    popd >/dev/null 2>&1

    echo "Collecting current data of innodb and myrocks tables"
    # Get record count for each table in databases test and test_rocksdb
    for ((i=1; i<=${num_tables}; i++)); do
        rc_innodb_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test.sbtest$i;")
        rc_myrocks_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test_rocksdb.sbtest$i;")
    #    echo "rc_innodb_orig[$i]: ${rc_innodb_orig[$i]}"
    #    echo "rc_myrocks_orig[$i]: ${rc_myrocks_orig[$i]}"
    done

    # Get checksum of each table in databases test and test_rocksdb
    for ((i=1; i<=${num_tables}; i++)); do
        chk_innodb_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
        chk_myrocks_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test_rocksdb.sbtest$i;"|awk '{print $2}')
    #    echo "chk_innodb_orig[$i]: ${chk_innodb_orig[$i]}"
    #    echo "chk_myrocks_orig[$i]: ${chk_myrocks_orig[$i]}"
    done

    echo "Stopping mysql server and moving data directory"
    ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock shutdown
    if [ -d ${mysqldir}/data_orig_$(date +"%d_%m_%Y") ]; then
        rm -r ${mysqldir}/data_orig_$(date +"%d_%m_%Y")
    fi
    mv ${mysqldir}/data ${mysqldir}/data_orig_$(date +"%d_%m_%Y")

    echo "Restoring full backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --copy-back --target-dir=${backup_dir}/full --datadir=${datadir} ${RESTORE_PARAMS} 2>${logdir}/res_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
        exit 1
    else
        echo "Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
    fi

    echo "Starting mysql server"
    pushd $mysqldir >/dev/null 2>&1
    ./start --log-bin=binlog ${MYSQLD_OPTIONS} >/dev/null 2>&1 
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. The restore was unsuccessful. Database logs: ${mysqldir}/log"
        popd >/dev/null 2>&1
        exit 1
    fi
    echo "The mysql server was started successfully"
    popd >/dev/null 2>&1

    echo "Check xtrabackup for binlog position"
    xb_binlog_file=$(cat ${backup_dir}/full/xtrabackup_binlog_info|awk '{print $1}')
    xb_binlog_pos=$(cat ${backup_dir}/full/xtrabackup_binlog_info|awk '{print $2}')
    echo "Xtrabackup binlog position: $xb_binlog_file, $xb_binlog_pos"

    echo "Applying binlog to restored data starting from $xb_binlog_file, $xb_binlog_pos"
    ${mysqldir}/bin/mysqlbinlog ${mysqldir}/data_orig_$(date +"%d_%m_%Y")/$xb_binlog_file --start-position=$xb_binlog_pos | ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock
    if [ "$?" -ne 0 ]; then
        echo "ERR: The binlog could not be applied to the restored data"
    fi

    sleep 5
    echo "Checking restored data"
    echo "Check the table status"
    check_err=0
    for ((i=1; i<=${num_tables}; i++)); do
        for database in test test_rocksdb; do
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
            fi
        done
    done

    if [[ "$check_err" -eq 0 ]]; then
        echo "All innodb and myrocks tables status: OK"
    else
        echo "After restore, some tables may be corrupt, check table status is not OK"
    fi

    echo "Check the record count of tables in databases test and test_rocksdb"
    # Get record count for each table in databases test and test_rocksdb
    rc_err=0
    checksum_err=0
    for ((i=1; i<=${num_tables}; i++)); do
        rc_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test.sbtest$i;")
        if [[ "${rc_innodb_orig[$i]}" -ne "${rc_innodb_res[$i]}" ]]; then
            echo "ERR: The record count of test.sbtest$i changed after restore. Record count in original data: ${rc_innodb_orig[$i]}. Record count in restored data: ${rc_innodb_res[$i]}."
            rc_err=1
        fi

        rc_myrocks_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test_rocksdb.sbtest$i;")
        if [[ "${rc_myrocks_orig[$i]}" -ne "${rc_myrocks_res[$i]}" ]]; then
            echo "ERR: The record count of test_rocksdb.sbtest$i changed after restore. Record count in original data: ${rc_myrocks_orig[$i]}. Record count in restored data: ${rc_myrocks_res[$i]}."
            rc_err=1
        fi
        #echo "rc_innodb_res[$i]: ${rc_innodb_res[$i]}"
        #echo "rc_myrocks_res[$i]: ${rc_myrocks_res[$i]}"
    done
    if [[ "$rc_err" -eq 0 ]]; then
        echo "Match record count of tables in databases test and test_rocksdb with original data: Pass"
    fi

    echo "Check the checksum of each table in databases test and test_rocksdb"
    # Get checksum of each table in databases test and test_rocksdb
    for ((i=1; i<=${num_tables}; i++)); do
        chk_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
        if [[ "${chk_innodb_orig[$i]}" -ne "${chk_innodb_res[$i]}" ]]; then
            echo "ERR: The checksum of test.sbtest$i changed after restore. Checksum in original data: ${chk_innodb_orig[$i]}. Checksum in restored data: ${chk_innodb_res[$i]}."
            checksum_err=1;
        fi

        chk_myrocks_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test_rocksdb.sbtest$i;"|awk '{print $2}')
        if [[ "${chk_myrocks_orig[$i]}" -ne "${chk_myrocks_res[$i]}" ]]; then
            echo "ERR: The checksum of test_rocksdb.sbtest$i changed after restore. Checksum in original data: ${chk_myrocks_orig[$i]}. Checksumin restored data: ${chk_myrocks_res[$i]}."
            checksum_err=1;
        fi
        #echo "chk_innodb_res[$i]: ${chk_innodb_res[$i]}"
        #echo "chk_myrocks_res[$i]: ${chk_myrocks_res[$i]}"
    done

    if [[ "$checksum_err" -eq 0 ]]; then
        echo "Match checksum of all tables in databases test and test_rocksdb with original data: Pass"
    fi

    echo "Check for gaps in primary sequence id of tables"
    gap_found=0
    for database in test test_rocksdb; do
        for ((i=1; i<=${num_tables}; i++)); do
            j=1
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT id FROM $database.sbtest$i ORDER BY id ASC" | while read line; do
            if [[ "$line" != "$j" ]]; then
                echo "ERR: Gap found in $database.sbtest$i. Expected sequence number for ID is: $j. Actual sequence number for ID is: $line."
                gap_found=1
                break
            fi
            let j++
            done
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
    done ) &

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
    done ) &
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

    echo "Change the compression of a myrocks table"
    #${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "set global rocksdb_update_cf_options='cf1={compression=kZlibCompression;bottommost_compression=kZlibCompression};cf2={compression=kLZ4Compression;bottommost_compression=kLZ4Compression};cf3={compression=kZSTDNotFinalCompression;bottommost_compression=kZSTDNotFinalCompression};cf4={compression=kNoCompression;bottommost_compression=kNoCompression}';"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "set global rocksdb_update_cf_options='cf1={compression=kZlibCompression};cf2={compression=kLZ4Compression};cf3={compression=kZSTDNotFinalCompression};cf4={compression=kNoCompression}';"
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
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test1_innodb.sbtest1 ADD COLUMN b JSON AS('{"k1": "value", "k2": [10, 20]}');" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test1_innodb.sbtest1 DROP COLUMN b;" >/dev/null 2>&1
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP DATABASE test1_innodb;" >/dev/null 2>&1
    done ) &

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

    incremental_backup "--lock-ddl"
}

test_rename_index() {
    # This test suite takes an incremental backup when an index is renamed

    echo "Test: Backup and Restore during rename index"

    rename_index

    incremental_backup
}

test_add_drop_tablespace() {
    # This test suite takes an incremental backup when a tablespace is added and dropped

    echo "Test: Backup and Restore during add and drop tablespace"

    add_drop_tablespace

    incremental_backup "--lock-ddl"
}

test_change_compression() {
    # This test suite takes an incremental backup when the compression of a table is changed

    echo "Test: Backup and Restore during change in compression"

    change_compression

    incremental_backup
}

test_change_row_format() {
    # This test suite takes an incremental backup when the row format of a table is changed

    echo "Test: Backup and Restore during change in row format"

    change_row_format

    incremental_backup "--lock-ddl"
}

test_copy_data_across_engine() {
    # This test suite copies a table from one storage engine to another and then takes an incremental backup

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
}

test_add_data_across_engine() {
    # This test suite adds data in tables of innodb, rocksdb engines simultaneously

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
}

test_update_truncate_table() {
    # This test suite takes an incremental backup during update and truncate of tables

    echo "Test: Backup and Restore during update and truncate of a table"

    update_truncate_table

    incremental_backup "--lock-ddl"
}

test_create_drop_database() {
    # This test suite takes an incremental backup during create and drop of a database

    echo "Test: Backup and Restore during create and drop of a database"

    initialize_db

    create_drop_database

    incremental_backup "--lock-ddl"
}

test_run_all_statements() {
    # This test suite runs the statements for all previous tests simultaneously in background

    # Change storage engine does not work due to PS-5559 issue
    #change_storage_engine

    add_drop_index

    add_drop_tablespace

    change_compression

    change_row_format

    update_truncate_table

    incremental_backup "--lock-ddl"
}

test_inc_backup_encryption() {
    # This test suite takes an incremental backup when PS is running with encryption
    local encrypt_type="$1"

    # Note: Binlog cannot be applied to backup if it is encrypted

    if [ "${encrypt_type}" = "keyring_file" ]; then
        echo "Test: Incremental Backup and Restore for PS with keyring_file encryption"

        initialize_db "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_tables=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files"

        incremental_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_tables=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files"
    else
        echo "Test: Incremental Backup and Restore for PS with keyring_vault encryption"
        initialize_db "--early-plugin-load=keyring_vault=keyring_vault.so --keyring_vault_config=${vault_config} --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_tables=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files"

        incremental_backup "--keyring_vault_config=${vault_config} --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_vault_config=${vault_config} --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_vault_config=${vault_config} --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--early-plugin-load=keyring_vault=keyring_vault.so --keyring_vault_config=${vault_config} --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_tables=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files"
    fi

}

test_streaming_backup() {
    # This test suite tests incremental backup when it is streamed

    echo "Test: Incremental Backup and Restore with streaming"

    initialize_db

    incremental_backup "" "" "" "--log-bin=binlog" "stream" ""
}

test_compress_stream_backup() {
    # This test suite tests incremental backup when it is compressed and streamed

    echo "Test: Incremental Backup and Restore with compression and streaming"

    incremental_backup "--compress --compress-threads=10" "" "" "--log-bin=binlog" "stream" ""
}

test_encrypt_compress_stream_backup() {
    # This test suite tests incremental backup when it is encrypted, compressed and streamed

    echo "Test: Incremental Backup and Restore with compression, encryption and streaming"

    incremental_backup "--encrypt=AES256 --encrypt-key=${encrypt_key} --encrypt-threads=10 --encrypt-chunk-size=128K --compress --compress-threads=10" "" "" "--log-bin=binlog" "stream" ""
}

test_cloud_inc_backup() {
    # This test suite tests incremental backup for cloud

    echo "Test: Incremental Backup and Restore with cloud"

    # This test requires the cloud options in a config file
    incremental_backup "--parallel=10" "" "" "" "cloud" "--defaults-file=${cloud_config}"
}


echo "Running Tests"
# Various test suites
#for testsuite in test_inc_backup test_chg_storage_eng test_add_drop_index test_rename_index test_add_drop_tablespace test_change_compression test_change_row_format test_copy_data_across_engine test_add_data_across_engine test_update_truncate_table test_run_all_statements; do

# Encryption test suites
#for testsuite in "test_inc_backup_encryption keyring_file" "test_inc_backup_encryption keyring_vault"; do

# File encryption, compression and streaming test suites
#for testsuite in test_streaming_backup test_compress_stream_backup test_encrypt_compress_stream_backup; do

# Cloud backup
for testsuite in test_cloud_inc_backup; do
    $testsuite
    echo "###################################################################################"
done
