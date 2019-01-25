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
export xtrabackup_dir="$HOME/pxb_8_0_debug_build_GA/bin"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export mysqldir="$HOME/PS201218-percona-server-8.0.13-3-linux-x86_64-debug"
export datadir="$HOME/PS201218-percona-server-8.0.13-3-linux-x86_64-debug/data"
#export socket="$HOME/PS201218-percona-server-8.0.13-3-linux-x86_64-debug/socket.sock"
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

    ./all_no_cl --log-bin=mysql-bin ${MYSQLD_OPTIONS} >/dev/null 2>&1 
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
    #sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock prepare
}

incremental_backup() {
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local MYSQLD_OPTIONS="$3"

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
    #sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test_rocksdb --mysql-user=root --threads=50 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &
    sleep 5

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

    echo "Stopping mysql server and moving data directory"
    ${mysqldir}/bin/mysqladmin -uroot -S${mysqldir}/socket.sock shutdown
    if [ -d ${mysqldir}/data_orig_$(date +"%m_%d_%Y") ]; then
        rm -r ${mysqldir}/data_orig_$(date +"%m_%d_%Y")
    fi
    mv ${mysqldir}/data ${mysqldir}/data_orig_$(date +"%m_%d_%Y")

    echo "Restoring full backup"
    ${xtrabackup_dir}/xtrabackup --user=root --password='' --copy-back --target-dir=${backup_dir}/full --datadir=${datadir} 2>${logdir}/res_backup_$(date +"%d_%m_%Y_%M")_log

    echo "Starting mysql server"
    pushd $mysqldir >/dev/null 2>&1
    ./start --log-bin=mysql-bin ${MYSQLD_OPTIONS} >/dev/null 2>&1 
    ${mysqldir}/bin/mysqladmin ping --user=root --socket=${mysqldir}/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. The restore was unsuccessful. Database logs: ${mysqldir}/log"
        popd >/dev/null 2>&1
        exit 1
    fi
    echo "The mysql server was started successfully"
    popd >/dev/null 2>&1

    # TBD after myrocks backup implementation is completed
    echo "Checking backup"
    #~/pt-latest/bin/pt-table-checksum S=${mysqldir}/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format| awk '{print $4, $9}' | grep -E "ROWS|test"
}

clean_data() {
    # This function cleans rocksdb data

    # Cleanup required for rocksdb data until backup works properly
    echo "Clean and recreate rocksdb data"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "drop database if exists test_rocksdb;"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE DATABASE IF NOT EXISTS test_rocksdb;"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test_rocksdb --mysql-user=root --threads=100 --db-driver=mysql --mysql-storage-engine=ROCKSDB --mysql-socket=${mysqldir}/socket.sock prepare
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

#    echo "Change the storage engine of test_rocksdb.sbtest1 to INNODB, ROCKSDB, MYISAM continuously"
#    ( for ((i=1; i<=10; i++)); do
#        # Check if database is up otherwise exit the loop
#        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
#        if [ "$?" -ne 0 ]; then
#            break
#        fi
#        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=INNODB;" >/dev/null 2>&1
#        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=ROCKSDB;" >/dev/null 2>&1
#        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=MYISAM;" >/dev/null 2>&1
#        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "alter table test_rocksdb.sbtest1 ENGINE=ROCKSDB;" >/dev/null 2>&1
#    done ) &
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

#    echo "Add and drop an index in the test_rocksdb.sbtest1 table"
#    ( for ((i=1; i<=10; i++)); do
#        # Check if database is up otherwise exit the loop
#        ${mysqldir}/bin//mysqladmin ping --user=root --socket=${mysqldir}/socket.sock 2>/dev/null 1>&2
#        if [ "$?" -ne 0 ]; then
#            break
#        fi
#        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE INDEX kc on test_rocksdb.sbtest1 (k,c);" >/dev/null 2>&1
#        ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP INDEX kc on test_rocksdb.sbtest1;" >/dev/null 2>&1
#    done ) &
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

    #clean_data
}

test_chg_storage_eng() {
    # This test suite takes an incremental backup when the storage engine of a table is changed

    echo "Test: Backup and Restore during change in storage engine"
    
    change_storage_engine

    incremental_backup
    #clean_data
}

test_add_drop_index() {
    # This test suite takes an incremental backup when an index is added and dropped

    echo "Test: Backup and Restore during add and drop index"

    add_drop_index

    incremental_backup "--lock-ddl"

}

for testsuite in test_inc_backup test_chg_storage_eng test_add_drop_index; do
    $testsuite
    echo "###################################################################################"
done
