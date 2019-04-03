#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup for innodb and myrocks tables               #
# Assumption: PS8.0 and PXB8.0 are already installed                   #
# Usage:                                                               #
# 1. Set paths in this script:                                         #
#    xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir  # 
# 2. Run the script as: ./innodb_myrocks_backup_tests.sh               #
# 3. Logs are available in: logdir                                     #
########################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb_rocksdb_8_0_5_debug/bin"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export mysqldir="$HOME/PS180319_rocksdb_8_0_15_4_debug"
export datadir="$HOME/PS180319_rocksdb_8_0_15_4_debug/data"
#export socket="$HOME/PS180319_rocksdb_8_0_15_4_debug/socket.sock"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"

# Set sysbench variables
num_tables=10
table_size=1000

initialize_db() {
    # This function initializes and starts mysql database
    local MYSQLD_OPTIONS="$1"

    echo "Starting mysql database"
    pushd $mysqldir >/dev/null 2>&1
    if [ ! -f $mysqldir/all_no_cl ]; then
        $qascripts startup.sh
    fi

    ./all_no_cl ${MYSQLD_OPTIONS} >/dev/null 2>&1 
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Please check the directory"
        popd >/dev/null 2>&1
        exit 1
    fi
    popd >/dev/null 2>&1
}

create_data() {
    echo "Creating innodb data in database"
    which sysbench >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Sysbench not found, data could not be created"
        exit 1
    fi

    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock prepare

    echo "Creating rocksdb data in database"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test_rocksdb;"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock prepare
}

incremental_backup() {
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local RESTORE_PARAMS="$3"
    local MYSQLD_OPTIONS="$4"

    echo "Taking full backup"
    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    if [ ! -d ${logdir} ]; then
        mkdir ${logdir}
    fi

    ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/full_backup_$(date +"%d_%m_%Y_%M")_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_$(date +"%d_%m_%Y_%M")_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_$(date +"%d_%m_%Y_%M")_log"
    fi

    echo "Adding data in database"
    # Innodb data
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &

    # Rocksdb data
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &
    sleep 10

    #~/pt-latest/bin/pt-table-checksum S=${mysqldir}/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format| awk '{print $4, $9}' | grep -E "ROWS|test"

    echo "Taking incremental backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --backup --target-dir=${backup_dir}/inc --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc_backup_$(date +"%d_%m_%Y_%M")_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc_backup_$(date +"%d_%m_%Y_%M")_log"
        exit 1
    else
        echo "Inc backup was successfully created at: ${backup_dir}/inc. Logs available at: ${logdir}/inc_backup_$(date +"%d_%m_%Y_%M")_log"
    fi

    echo "Preparing full backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --prepare --apply-log-only --target_dir=${backup_dir}/full ${PREPARE_PARAMS} 2>${logdir}/prepare_full_backup_$(date +"%d_%m_%Y_%M")_log

    echo "Preparing incremental backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc ${PREPARE_PARAMS} 2>${logdir}/prepare_inc_backup_$(date +"%d_%m_%Y_%M")_log

    echo "Restart mysql server to stop all running queries"
    ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock shutdown
    sleep 2
    pushd $mysqldir >/dev/null 2>&1
    ./start ${MYSQLD_OPTIONS} >/dev/null 2>&1
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
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --copy-back --target-dir=${backup_dir}/full --datadir=${datadir} ${RESTORE_PARAMS} 2>${logdir}/res_backup_$(date +"%d_%m_%Y_%M")_log

    echo "Starting mysql server"
    pushd $mysqldir >/dev/null 2>&1
    ./start ${MYSQLD_OPTIONS} >/dev/null 2>&1 
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

    echo "Checking restored data"
    echo "Check the table status"
    for ((i=1; i<=${num_tables}; i++)); do
        for database in test test_rocksdb; do
            if ! table_status=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECK TABLE $database.sbtest$i"|cut -f4-); then
                echo "ERR: CHECK TABLE $database.sbtest$i query failed"
                # Check if database went down
                if ! ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1; then
                    echo "ERR: The database has gone down due to corruption in table $database.sbtest$i"
                fi
                exit 1
            fi

            if [[ "$table_status" != "OK" ]]; then
                echo "ERR: CHECK TABLE $database.sbtest$i query displayed the table status as '$table_status'"
                exit 1
            fi
        done
    done
    echo "All innodb and myrocks tables status: OK"

    echo "Check the record count of each table in databases test and test_rocksdb"
    # Get record count for each table in databases test and test_rocksdb
    rc_err=0
    chk_err=0
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
        echo "The record count of all tables in databases test and test_rocksdb matched successfully with original data"
    fi

    echo "Check the checksum of each table in databases test and test_rocksdb"
    # Get checksum of each table in databases test and test_rocksdb
    for ((i=1; i<=${num_tables}; i++)); do
        chk_innodb_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.sbtest$i;"|awk '{print $2}')
        if [[ "${chk_innodb_orig[$i]}" -ne "${chk_innodb_res[$i]}" ]]; then
            echo "ERR: The checksum of test.sbtest$i changed after restore. Checksum in original data: ${chk_innodb_orig[$i]}. Checksum in restored data: ${chk_innodb_res[$i]}."
            chk_err=1;
        fi

        chk_myrocks_res[$i]=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test_rocksdb.sbtest$i;"|awk '{print $2}')
        if [[ "${chk_myrocks_orig[$i]}" -ne "${chk_myrocks_res[$i]}" ]]; then
            echo "ERR: The checksum of test_rocksdb.sbtest$i changed after restore. Checksum in original data: ${chk_myrocks_orig[$i]}. Checksumin restored data: ${chk_myrocks_res[$i]}."
            chk_err=1;
        fi
        #echo "chk_innodb_res[$i]: ${chk_innodb_res[$i]}"
        #echo "chk_myrocks_res[$i]: ${chk_myrocks_res[$i]}"
    done
    if [[ "$chk_err" -eq 0 ]]; then
        echo "The checksum of all tables in databases test and test_rocksdb matched successfully with original data"
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
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test_rocksdb.sbtest1;" >/dev/null 2>&1
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
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=COMPRESSED;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=DYNAMIC;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=COMPACT;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test.sbtest2 ROW_FORMAT=REDUNDANT;"
    done ) &

    echo "Change the row format of a myrocks table"
    ( for ((i=1; i<=10; i++)); do
        # Check if database is up otherwise exit the loop
        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
        if [ "$?" -ne 0 ]; then
            break
        fi
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest2 ROW_FORMAT=COMPRESSED;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest2 ROW_FORMAT=DYNAMIC;"
        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "ALTER TABLE test_rocksdb.sbtest2 ROW_FORMAT=FIXED;"
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

###################################################################################
##                                  Test Suites                                  ##
###################################################################################

test_inc_backup() {
    # This test suite creates a database, takes a full backup, incremental backup and then restores the database

    echo "Running Tests"
    echo "Test: Incremental Backup and Restore"

    initialize_db

    create_data

    incremental_backup
}

test_chg_storage_eng() {
    # This test suite takes an incremental backup when the storage engine of a table is changed

    echo "Test: Backup and Restore during change in storage engine"
    
    initialize_db

    create_data

    change_storage_engine

    incremental_backup
}

test_add_drop_index() {
    # This test suite takes an incremental backup when an index is added and dropped

    echo "Test: Backup and Restore during add and drop index"

    initialize_db

    create_data

    add_drop_index

    incremental_backup "--lock-ddl"
}

test_add_drop_tablespace() {
    # This test suite takes an incremental backup when a tablespace is added and dropped

    echo "Test: Backup and Restore during add and drop tablespace"

    initialize_db

    create_data

    add_drop_tablespace

    incremental_backup "--lock-ddl"
}

test_change_compression() {
    # This test suite takes an incremental backup when the compression of a table is changed

    echo "Test: Backup and Restore during change in compression"

    #initialize_db

    #create_data

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
        echo "Row count of both tables innodb_t and myrocks_t is same after restore, the check passed"
    fi

    echo "Check the checksum of tables innodb_t and myrocks_t after restore"
    innodb_checksum=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.innodb_t;"|awk '{print $2}')
    myrocks_checksum=$(${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -Bse "CHECKSUM TABLE test.myrocks_t;"|awk '{print $2}')
    if [ "$innodb_checksum" -ne "$myrocks_checksum" ]; then
        echo "ERR: The checksum of tables innodb_t and myrocks_t is different. Checksum of innodb_t: $innodb_checksum. Checksum of myrocks_t: $myrocks_checksum"
        exit 1
    else
        echo "Checksum of both tables innodb_t and myrocks_t is same after restore, the check passed"
    fi
}

#for testsuite in test_inc_backup test_chg_storage_eng test_add_drop_index; do
for testsuite in test_inc_backup test_add_data_across_engine; do
    $testsuite
    echo "###################################################################################"
done
