#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup for tablespaces in different paths          #
# Assumption: PS8.0 and PXB8.0 are already installed as tarballs       #
# Usage:                                                               #
# 1. Set paths in this script:                                         #
#    xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir  #
# 2. Run the script as: ./tablespaces_backup_tests.sh                  #
# 3. Logs are available in: logdir                                     #
########################################################################

export xtrabackup_dir="$HOME/pxb_8_0_25_debug/bin"
export mysqldir="$HOME/MS_8_0_25"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"

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

take_backup() {
    # This function takes a full, incremental backup
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local RESTORE_PARAMS="$3"
    local MYSQLD_OPTIONS="$4"
    local BACKUP_TYPE="$5"

    log_date=$(date +"%d_%m_%Y_%M")

    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    echo "Taking full backup"
    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    sleep 1

    if [[ "${BACKUP_TYPE}" = "incremental" ]]; then
        echo "Taking incremental backup"
        ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc_backup_${log_date}_log
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

        echo "Preparing full backup"
        "${xtrabackup_dir}"/xtrabackup --prepare --apply-log-only --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
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

    innodb_data_home_dir=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@innodb_data_home_dir;")
    innodb_directories=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@innodb_directories;")
    innodb_undo_directory=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@innodb_undo_directory;")

    "${mysqldir}"/bin/mysqladmin -uroot -S "${mysqldir}"/socket.sock shutdown
    if [ -d ${mysqldir}/data_orig_$(date +"%d_%m_%Y") ]; then
        rm -r "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")
    fi
    mv "${mysqldir}"/data "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")
    for dir in "${innodb_data_home_dir}" "${innodb_directories}"; do
        if [[ "${dir}" != "NULL" ]] && [[ -n "${dir}" ]]; then
            echo "Moving ${dir}"
            mv "${dir}" "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")
        fi
    done

    if [[ -n "${innodb_undo_directory}" ]] && [[ "${innodb_undo_directory}" != "./" ]]; then
        echo "Moving ${innodb_undo_directory}"
        mv "${innodb_undo_directory}" "${mysqldir}"/data_orig_$(date +"%d_%m_%Y")
    fi

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

    check_tables

    echo "Check the restored data"
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

check_dir_structure() {
    # This function will check the directory structure after restore

    local innodb_data_home_dir="$1"
    local innodb_directories="$2"
    local innodb_undo_dir="$3"

    echo "Check directory structure"
    for file in "ib_buffer_pool" "ibdata1" "ibtmp1"; do
        if [ ! -f "${innodb_data_home_dir}"/"${file}" ]; then
            echo "ERR: The file ${file} was not found in ${innodb_data_home_dir}"
        fi
    done

    for file in "undo_001" "undo_002" "new_undo_1.ibu"; do
        if [ ! -f "${innodb_undo_dir}"/"${file}" ]; then
            echo "ERR: The file ${file} was not found in ${innodb_undo_dir}"
        fi
    done

    if [ ! -f ${innodb_directories}/tspod.ibd ]; then
        echo "ERR: The file tspod.ibd was not found in ${innodb_directories}"
    fi

    # Database name taken as test
    if [ ! -f ${innodb_directories}/test/sbtest11.ibd ]; then
        echo "ERR: The file sbtest1.ibd was not found in ${innodb_directories}/test"
    fi
}

test_tablespaces() {
    # Test suite for tablespace tests
    local innodb_data_home_dir="/tmp/sysdir"
    local innodb_directories="/tmp/tablespaces"
    local innodb_undo_dir="/tmp/undo"

    check_dependencies

    echo "Test: Full backup and restore with tablespaces"
    for dir in "${innodb_data_home_dir}" "${innodb_directories}" "${innodb_undo_dir}"; do
        if [ -d "${dir}" ]; then
            rm -r "${dir}"
        fi
        mkdir "${dir}"
    done

    initialize_db "--innodb-data-home-dir=${innodb_data_home_dir} --innodb-directories=${innodb_directories} --innodb-undo-directory=${innodb_undo_dir}"

    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "CREATE UNDO TABLESPACE undo_tablespace_1 ADD DATAFILE 'new_undo_1.ibu';"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLESPACE tspod ADD DATAFILE '$innodb_directories/tspod.ibd' Engine=Innodb;"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "ALTER TABLE test.sbtest1 TABLESPACE tspod;"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE sbtest11 DATA DIRECTORY = '$innodb_directories' AS SELECT * FROM sbtest1;" test

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=5 run >>"${logdir}"/sysbench.log &

    take_backup "" "" "--innodb-data-home-dir=${innodb_data_home_dir} --innodb-undo-directory=${innodb_undo_dir}" "--innodb-data-home-dir=${innodb_data_home_dir} --innodb-directories=${innodb_directories} --innodb-undo-directory=${innodb_undo_dir}"
    
    check_dir_structure "${innodb_data_home_dir}" "${innodb_directories}" "${innodb_undo_dir}"

    echo "###################################################################################"

    echo "Test: Incremental backup and restore with tablespaces"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=10 run >>"${logdir}"/sysbench.log &

    take_backup "" "" "--innodb-data-home-dir=${innodb_data_home_dir} --innodb-undo-directory=${innodb_undo_dir}" "--innodb-data-home-dir=${innodb_data_home_dir} --innodb-directories=${innodb_directories} --innodb-undo-directory=${innodb_undo_dir}" "incremental"
    
    check_dir_structure "${innodb_data_home_dir}" "${innodb_directories}" "${innodb_undo_dir}"
}

test_tablespaces_encrypt() {
    # Test suite for tablespace tests with encryption
    local innodb_data_home_dir="/tmp/sysdir"
    local innodb_directories="/tmp/tablespaces"
    local innodb_undo_dir="/tmp/undo"

    check_dependencies

    echo "Test: Full backup and restore with tablespaces and encryption enabled"
    for dir in "${innodb_data_home_dir}" "${innodb_directories}" "${innodb_undo_dir}"; do
        if [ -d "${dir}" ]; then
            rm -r "${dir}"
        fi
        mkdir "${dir}"
    done

    if ${mysqldir}/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then
        server_type="MS"
        server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --table-encryption-privilege-check=ON"
    else
        server_type="PS"
        server_options="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --innodb_parallel_dblwr_encrypt --table-encryption-privilege-check=ON"
    fi

    initialize_db "${server_options} --innodb-data-home-dir=${innodb_data_home_dir} --innodb-directories=${innodb_directories} --innodb-undo-directory=${innodb_undo_dir}"

    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "CREATE UNDO TABLESPACE undo_tablespace_1 ADD DATAFILE 'new_undo_1.ibu';"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLESPACE tspod ADD DATAFILE '$innodb_directories/tspod.ibd' Engine=Innodb;"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "ALTER TABLE test.sbtest1 TABLESPACE tspod;"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE sbtest11 DATA DIRECTORY = '$innodb_directories' AS SELECT * FROM sbtest1;" test

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=5 run >>"${logdir}"/sysbench.log &

    take_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --innodb-data-home-dir=${innodb_data_home_dir} --innodb-undo-directory=${innodb_undo_dir}" "${server_options} --innodb-data-home-dir=${innodb_data_home_dir} --innodb-directories=${innodb_directories} --innodb-undo-directory=${innodb_undo_dir}"
    
    check_dir_structure "${innodb_data_home_dir}" "${innodb_directories}" "${innodb_undo_dir}"

    echo "###################################################################################"

    echo "Test: Incremental backup and restore with tablespaces and encryption enabled"

    echo "Run a load"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=10 run >>"${logdir}"/sysbench.log &

    take_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --innodb-data-home-dir=${innodb_data_home_dir} --innodb-undo-directory=${innodb_undo_dir}" "${server_options} --innodb-data-home-dir=${innodb_data_home_dir} --innodb-directories=${innodb_directories} --innodb-undo-directory=${innodb_undo_dir}" "incremental"
    
    check_dir_structure "${innodb_data_home_dir}" "${innodb_directories}" "${innodb_undo_dir}"
}

echo "################################## Running Tests ##################################"
test_tablespaces
echo "###################################################################################"
test_tablespaces_encrypt
echo "###################################################################################"
