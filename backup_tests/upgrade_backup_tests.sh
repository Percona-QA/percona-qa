#!/bin/bash

#############################################################################
# Created By Manish Chawla, Percona LLC                                     #
# This script tests backup during upgrade from previous to current version  #
# Assumption: PS8.0 and PXB8.0 are already installed                        #
# Usage:                                                                    #
# 1. Set paths in this script:                                              #
#    xtrabackup_dir, previous_xtrabackup_dir, backup_dir, mysqldir,         #
#    datadir, qascripts, logdir                                             #
# 2. Run the script as: ./upgrade_backup_tests.sh                           #
# 3. Logs are available in: logdir                                          #
#############################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb_8_0_25_debug/bin"
export previous_xtrabackup_dir="$HOME/pxb_8_0_23_debug/bin"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export mysqldir="$HOME/PS_8_0_23_14_glibc217"
export datadir="${mysqldir}/data"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"
export PATH="$PATH:$xtrabackup_dir"
rocksdb="enabled" # Set this to disabled for PXB2.4 and MySQL versions


# Set sysbench variables
num_tables=10
table_size=1000

check_dependencies() {
    # This function checks if the required dependencies are installed

    if ! sysbench --version >/dev/null 2>&1 ; then
        echo "ERR: The sysbench tool is not installed. It is required to run load."
        exit 1
    fi

    if ! pt-table-checksum --version >/dev/null 2>&1 ; then
        exit 1
        echo "ERR: The percona toolkit is not installed. It is required to check the data."
    fi
}

initialize_db() {
    # This function initializes and starts mysql database
    local MYSQLD_OPTIONS="$1"

    echo "Starting mysql database"
    pushd "$mysqldir" >/dev/null 2>&1 || exit
    if [ ! -f "$mysqldir"/all_no_cl ]; then
        "$qascripts"/startup.sh
    fi

    ./all_no_cl "${MYSQLD_OPTIONS}" >/dev/null 2>&1 
    "${mysqldir}"/bin/mysqladmin ping --user=root --socket="${mysqldir}"/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Please check the directory"
        popd >/dev/null 2>&1 || exit
        exit 1
    fi
    popd >/dev/null 2>&1 || exit

    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';"
    echo "Create data using sysbench"
    if [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock prepare >"${logdir}"/sysbench.log

        if [ "${rocksdb}" = "enabled" ]; then
            echo "Creating rocksdb data in database"
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test_rocksdb;"
            sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock prepare >>"${logdir}"/sysbench.log
        fi

    else
        # Encryption enabled
        for ((i=1; i<=num_tables; i++)); do
            echo "Creating the table sbtest$i..."
            "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE test.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y';"
        done

        echo "Adding data in tables..."
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=30 run >/dev/null 2>&1
    fi
}

take_full_backup() {
    # This function takes a full backup
    local XTRABACKUP_DIR="$1"
    local BACKUP_PARAMS="$2"

    log_date=$(date +"%d_%m_%Y_%M")

    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    echo "Taking full backup"
    "${XTRABACKUP_DIR}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    sleep 1
}

take_incremental_backup() {
    # This function takes an incremental backup
    local XTRABACKUP_DIR="$1"
    local BACKUP_PARAMS="$2"

    echo "Taking incremental backup"
    "${XTRABACKUP_DIR}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc_backup_${log_date}_log"
        exit 1
    else
        echo "Inc backup was successfully created at: ${backup_dir}/inc. Logs available at: ${logdir}/inc_backup_${log_date}_log"
    fi
}

prepare_restore_backup() {
    # This function prepares and restores a backup
    local PREPARE_PARAMS="$1"
    local RESTORE_PARAMS="$2"
    local MYSQLD_OPTIONS="$3"
    local BACKUP_TYPE="$4"

    if [[ "${BACKUP_TYPE}" = "incremental" ]]; then
        echo "Preparing full backup"
        "${xtrabackup_dir}"/xtrabackup --prepare --apply-log-only --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
            exit 1
        else
            echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
        fi

        echo "Preparing incremental backup"
        "${xtrabackup_dir}"/xtrabackup --user=root --password='' --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc ${PREPARE_PARAMS} 2>${logdir}/prepare_inc_backup_${log_date}_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc_backup_${log_date}_log"
            exit 1
        else
            echo "Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc_backup_${log_date}_log"
        fi
    else

        # Full backup prepare
        echo "Preparing full backup"
        "${xtrabackup_dir}"/xtrabackup --prepare --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
        if [ "$?" -ne 0 ]; then
            echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
            exit 1
        else
            echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
        fi
    fi

    # Collect data before restore
    orig_data=$(pt-table-checksum S="${mysqldir}"/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format --no-version-check 2>/dev/null | awk '{print $4}')

    echo "Stopping mysql server and moving data directory"

    "${mysqldir}"/bin/mysqladmin -uroot -S "${mysqldir}"/socket.sock shutdown
    if [ -d ${mysqldir}/data_orig_$(date +"%d_%m_%Y") ]; then
        rm -r "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")
    fi
    mv "${mysqldir}"/data "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")

    echo "Restoring full backup"
    "${xtrabackup_dir}"/xtrabackup --copy-back --target-dir="${backup_dir}"/full --datadir="${mysqldir}"/data ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
        exit 1
    else
        echo "Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
    fi

    echo "Starting mysql server"
    pushd "$mysqldir" >/dev/null 2>&1 || exit
    ./start "${MYSQLD_OPTIONS}" >/dev/null 2>&1
    "${mysqldir}"/bin/mysqladmin ping --user=root --socket="${mysqldir}"/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. The restore was unsuccessful. Database logs: ${mysqldir}/log"
        popd >/dev/null 2>&1 || exit
        exit 1
    fi
    echo "The mysql server was started successfully"

    # Binlog can't be applied if binlog is encrypted or skipped
    if [[ "${MYSQLD_OPTIONS}" != *"binlog-encryption" ]] && [[ "${MYSQLD_OPTIONS}" != *"--encrypt-binlog"* ]] && [[ "${MYSQLD_OPTIONS}" != *"skip-log-bin"* ]]; then
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

    echo "Check the restored data"
    check_tables

    # Collect data after restore
    res_data=$(pt-table-checksum S="${mysqldir}"/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format --no-version-check 2>/dev/null | awk '{print $4}')

    if [[ "${orig_data}" != "${res_data}" ]]; then
        echo "ERR: Data changed after restore."
        echo "Original data: ${orig_data}"
        echo "Restored data: ${res_data}"
    else
        echo "Restored data is correct"
    fi
}

check_tables() {
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

######################## Test Suites ##############################

test_upgrade_full_backup() {
    # This test suite checks upgrade during full backup

    echo "Test: Full backup and restore"
    echo "Full backup using previous xtrabackup version and prepare/restore using current xtrabackup version"

    initialize_db "--log-bin=binlog"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=20 run >>"${logdir}"/sysbench.log &

    if [ "${rocksdb}" = "enabled" ]; then
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=20 run >>"${logdir}"/sysbench.log &
    fi

    take_full_backup "${previous_xtrabackup_dir}" ""

    prepare_restore_backup "" "" "--log-bin=binlog" "full"
}

test_upgrade_inc_backup() {
    # This test suite checks upgrade during incremental backup

    echo "Test: Full, Incremental backup using previous xtrabackup version and prepare/restore using current xtrabackup version"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=30 run >>"${logdir}"/sysbench.log &

    if [ "${rocksdb}" = "enabled" ]; then
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=30 run >>"${logdir}"/sysbench.log &
    fi

    take_full_backup "${previous_xtrabackup_dir}" ""

    take_incremental_backup "${previous_xtrabackup_dir}" ""

    prepare_restore_backup "" "" "--log-bin=binlog" "incremental"

    echo "###################################################################################"

    echo "Test: Full backup using previous xtrabackup version, incremental backup and prepare/restore using current xtrabackup version"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=30 run >>"${logdir}"/sysbench.log &

    if [ "${rocksdb}" = "enabled" ]; then
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=30 run >>"${logdir}"/sysbench.log &
    fi

    take_full_backup "${previous_xtrabackup_dir}" ""

    take_incremental_backup "${xtrabackup_dir}" ""

    prepare_restore_backup "" "" "--log-bin=binlog" "incremental"
}

test_upgrade_backup_encrypt() {
    # Upgrade tests with encryption

    echo "Full backup and restore with encryption"
    echo "Test: Full backup using previous xtrabackup version and prepare/restore using current xtrabackup version"

    if "${mysqldir}"/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then

        # Server is MS 8.0
        server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"

    elif "${mysqldir}"/bin/mysqld --version | grep "8.0" >/dev/null 2>&1 ; then

        # Server is PS 8.0
        server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --innodb_parallel_dblwr_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --innodb-default-encryption-key-id=4294967295"

    else

        # Server is PS/MS 5.7
        server_options="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"
    fi

    initialize_db "${server_options}"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=20 run >>"${logdir}"/sysbench.log &

    take_full_backup "${previous_xtrabackup_dir}" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${previous_xtrabackup_dir}/../lib/plugin"

    prepare_restore_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${server_options}" "full"

    echo "###################################################################################"

    echo "Incremental backup and restore with encryption"

    echo "Test: Full, Incremental backup using previous xtrabackup version and prepare/restore using current xtrabackup version"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=30 run >>"${logdir}"/sysbench.log &

    take_full_backup "${previous_xtrabackup_dir}" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${previous_xtrabackup_dir}/../lib/plugin"

    take_incremental_backup "${previous_xtrabackup_dir}" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${previous_xtrabackup_dir}/../lib/plugin"

    prepare_restore_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${server_options}" "incremental"

    echo "###################################################################################"

    echo "Test: Full backup using previous xtrabackup version, incremental backup and prepare/restore using current xtrabackup version"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=30 run >>"${logdir}"/sysbench.log &

    take_full_backup "${previous_xtrabackup_dir}" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${previous_xtrabackup_dir}/../lib/plugin"

    take_incremental_backup "${xtrabackup_dir}" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin"

    prepare_restore_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${server_options}" "incremental"
}

echo "################################## Running Tests ##################################"
check_dependencies
test_upgrade_full_backup
echo "###################################################################################"
test_upgrade_inc_backup
echo "###################################################################################"
test_upgrade_backup_encrypt
