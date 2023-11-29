#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup for innodb tables                           #
# Assumption: PS8.0 and PXB8.0 are already installed                   #
# Usage:                                                               #
# 1. Set paths in this script:                                         #
#    xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir  # 
# 2. Run the script as: ./innodb_myrocks_backup_tests.sh               #
# 3. Logs are available in: logdir                                     #
########################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb-8.0/bld_8.0.35/install/bin"
export mysqldir="$HOME/mysql-8.0/bld_8.0.35/install"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"

# Set sysbench variables
num_tables=10
table_size=1000

initialize_db() {
    # This function initializes, starts and creates the mysql database
    local MYSQLD_OPTIONS="$1"

    echo "Starting mysql database"
    pushd $mysqldir >/dev/null 2>&1
    if [ ! -f $mysqldir/all_no_cl ]; then
        $qascripts/startup.sh
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
}

incremental_backup() {
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local RESTORE_PARAMS="$3"
    local MYSQLD_OPTIONS="$4"

    log_date=$(date +"%d_%m_%Y_%M")
    echo "Taking full backup"
    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    if [ ! -d ${logdir} ]; then
        mkdir ${logdir}
    fi

    ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/full_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    echo "Adding data in database"
    # Innodb data
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &

    sleep 5

    echo "Taking incremental backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc_backup_${log_date}_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc_backup_${log_date}_log"
        exit 1
    else
        echo "Inc backup was successfully created at: ${backup_dir}/inc. Logs available at: ${logdir}/inc_backup_${log_date}_log"
    fi

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

    echo "Collecting current data of innodb tables"
    # Get record count for each table in database test
    for ((i=1; i<=${num_tables}; i++)); do
        rc_innodb_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test.sbtest$i;")
    #    echo "rc_innodb_orig[$i]: ${rc_innodb_orig[$i]}"
    done

    # Get checksum of each table in database test
    for ((i=1; i<=${num_tables}; i++)); do
        chk_innodb_orig[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
    #    echo "chk_innodb_orig[$i]: ${chk_innodb_orig[$i]}"
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
        for database in test; do
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
        echo "All innodb tables status: OK"
    else
        echo "After restore, some tables may be corrupt, check table status is not OK"
    fi

    echo "Check the record count of tables in database test"
    # Get record count for each table in database test
    rc_err=0
    checksum_err=0
    for ((i=1; i<=${num_tables}; i++)); do
        rc_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "SELECT COUNT(*) FROM test.sbtest$i;")
        if [[ "${rc_innodb_orig[$i]}" -ne "${rc_innodb_res[$i]}" ]]; then
            echo "ERR: The record count of test.sbtest$i changed after restore. Record count in original data: ${rc_innodb_orig[$i]}. Record count in restored data: ${rc_innodb_res[$i]}."
            rc_err=1
        fi

        #echo "rc_innodb_res[$i]: ${rc_innodb_res[$i]}"
    done
    if [[ "$rc_err" -eq 0 ]]; then
        echo "Match record count of tables in database test with original data: Pass"
    fi

    echo "Check the checksum of each table in database test"
    # Get checksum of each table in database test
    for ((i=1; i<=${num_tables}; i++)); do
        chk_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
        if [[ "${chk_innodb_orig[$i]}" -ne "${chk_innodb_res[$i]}" ]]; then
            echo "ERR: The checksum of test.sbtest$i changed after restore. Checksum in original data: ${chk_innodb_orig[$i]}. Checksum in restored data: ${chk_innodb_res[$i]}."
            checksum_err=1;
        fi

        #echo "chk_innodb_res[$i]: ${chk_innodb_res[$i]}"
    done

    if [[ "$checksum_err" -eq 0 ]]; then
        echo "Match checksum of all tables in database test with original data: Pass"
    fi

    echo "Check for gaps in primary sequence id of tables"
    gap_found=0
    for database in test; do
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
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test.sbtest1;" >/dev/null 2>&1
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
}

###################################################################################
##                                  Test Suites                                  ##
###################################################################################

test_inc_backup() {
    # This test suite creates a database, takes a full backup, incremental backup and then restores the database

    echo "Running Tests"
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

test_update_truncate_table() {
    # This test suite takes an incremental backup during update and truncate of tables

    echo "Test: Backup and Restore during update and truncate of a table"

    update_truncate_table

    incremental_backup "--lock-ddl"
}

test_run_all_statements() {
    # This test suite runs the statements for all previous tests simultaneously in background

    change_storage_engine

    add_drop_index

    add_drop_tablespace

    change_compression

    change_row_format

    update_truncate_table

    incremental_backup "--lock-ddl"
}

test_inc_backup_encryption() {
    # This test suite takes an incremental backup when PS is running with encryption

    echo "Test: Incremental Backup and Restore for PS with encryption"

    # Note: Binlog cannot be applied to backup if it is encrypted

    # For PS optimized build
    #initialize_db "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_tables=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files"

    # For PS debug build
    initialize_db "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_online_alter_logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"

    incremental_backup "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --innodb_encrypt_online_alter_logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"
}

#for testsuite in test_inc_backup test_chg_storage_eng test_add_drop_index test_add_drop_tablespace test_change_compression test_change_row_format test_update_truncate_table test_run_all_statements; do
for testsuite in test_inc_backup_encryption; do
    $testsuite
    echo "###################################################################################"
done
