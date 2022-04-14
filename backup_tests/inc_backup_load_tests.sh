#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script tests backup with a load tool as pquery/pstress/sysbench #
# Assumption: PS8.0 and PXB8.0 are already installed as tarballs       #
# Usage:                                                               #
# 1. Compile pquery/pstress with mysql                                 #
# 2. Set variables in this script:                                     #
#    xtrabackup_dir, mysqldir, datadir, backup_dir, qascripts, logdir, #
#    load_tool, tool_dir, num_tables, table_size, kmip configuration   #
# 3. Run the script as: ./inc_backup_load_tests.sh <Test Suite>        #
# 4. Logs are available in: logdir                                     #
########################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb_8_0_27_debug/bin"
export mysqldir="$HOME/PS260122_8_0_27_18_debug"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"

# Set tool variables
load_tool="pstress" # Set value as pquery/pstress/sysbench
num_tables=10 # Used for Sysbench
table_size=1000 # Used for Sysbench
tool_dir="$HOME/pstress/src" # Pquery/pstress dir

# Set Kmip configuration
kmip_server_address="0.0.0.0"
kmip_server_port=5696
kmip_client_ca="/home/manish.chawla/cert.pem"
kmip_client_key="/home/manish.chawla/key.pem"
kmip_server_ca="/home/manish.chawla/ca.pem"

initialize_db() {
    # This function initializes and starts mysql database

    if [ ! -d "${logdir}" ]; then
        mkdir "${logdir}"
    fi

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

run_load() {
    # This function runs a load using pquery/sysbench

    local tool_options="$1"

    if [[ "${load_tool}" = "pquery" ]]; then
        echo "Run pquery"
        pushd "$tool_dir" >/dev/null 2>&1 || exit
        if [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
            ./pquery2-ps --tables 10 --logdir="$HOME"/backuplogs --records 200 --threads 10 --seconds 30 --socket "${mysqldir}"/socket.sock -k --no-encryption --undo-tbs-sql 0 >"${logdir}"/pquery.log &
        else
            # Encryption enabled
            ./pquery2-ps --tables 10 --logdir="$HOME"/backuplogs --records 200 --threads 10 --seconds 30 --socket "${mysqldir}"/socket.sock -k --undo-tbs-sql 0 >"${logdir}"/pquery.log &
        fi
        popd >/dev/null 2>&1 || exit
        sleep 2
    elif [[ "${load_tool}" = "pstress" ]]; then
        echo "Run pstress with options: ${tool_options}"
        pushd "$tool_dir" >/dev/null 2>&1 || exit
        ./pstress-ps ${tool_options} --logdir="${logdir}" --socket "${mysqldir}"/socket.sock >"${logdir}"/pstress.log &
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

    echo "Taking full backup"
    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    sleep 1
    inc_num=1
    while [[ $(pgrep ${load_tool}) ]]; do
        echo "Taking incremental backup: $inc_num"
        if [[ "${inc_num}" -eq 1 ]]; then
            "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
        else
            "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
        fi
        if [ "$?" -ne 0 ]; then
            grep -e "PXB will not be able to make a consistent backup" -e "PXB will not be able to take a consistent backup" "${logdir}"/inc${inc_num}_backup_"${log_date}"_log
            if [ "$?" -eq 0 ]; then
                echo "Retrying incremental backup with --lock-ddl option"
                rm -r "${backup_dir}"/inc${inc_num}

                if [[ "${inc_num}" -eq 1 ]]; then
                    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --lock-ddl 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
                else
                    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} --lock-ddl 2>>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
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
            echo "Inc backup was successfully created at: ${backup_dir}/inc${inc_num}. Logs available at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
        fi
        let inc_num++
        sleep 2
    done

    echo "Preparing full backup"
    "${xtrabackup_dir}"/xtrabackup --prepare --apply-log-only --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    for ((i=1; i<inc_num; i++)); do

        echo "Preparing incremental backup: $i"
        if [[ "${i}" -eq "${inc_num}-1" ]]; then
            "${xtrabackup_dir}"/xtrabackup --prepare --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
        else
            "${xtrabackup_dir}"/xtrabackup --prepare --apply-log-only --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
        fi
        if [ "$?" -ne 0 ]; then
            echo "ERR: Prepare of incremental backup failed. Please check the log at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
            exit 1
        else
            echo "Prepare of incremental backup was successful. Logs available at: ${logdir}/prepare_inc${i}_backup_${log_date}_log"
        fi
    done

    echo "Collecting existing table count"
    pushd "$mysqldir" >/dev/null 2>&1 || exit
    pt-table-checksum S=${PWD}/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format| awk '{print $4,$9}' >file1
    popd >/dev/null 2>&1 || exit
    sleep 2

    echo "Stopping mysql server and moving data directory"
    "${mysqldir}"/bin/mysqladmin -uroot -S"${mysqldir}"/socket.sock shutdown
    if [ -d "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")" ]; then
        rm -r "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")"
    fi
    mv "${mysqldir}"/data "${mysqldir}"/data_orig_"$(date +"%d_%m_%Y")"

    echo "Restoring full backup"
    "${xtrabackup_dir}"/xtrabackup --copy-back --target-dir="${backup_dir}"/full --datadir="${datadir}" ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
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
        pt-table-checksum S=${PWD}/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format| awk '{print $4,$9}' >file2
        diff file1 file2
        if [ "$?" -ne 0 ]; then
            echo "ERR: Difference found in table count before and after restore."
        else
            echo "Data is the same before and after restore: Pass"
        fi
        popd >/dev/null 2>&1 || exit
    else
        echo "Binlog applying skipped, ignore differences between actual data and restored data"

    fi
}

count_rows() {
    if [ ! -z "$1" ]; then
        database="$1"
    else
        database=test
    fi

    while read table; do
        echo -n "Row count for $database.$table: "
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select count(*) from $database.$table"
    done < <("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "SHOW TABLES FROM $database;")

    while read table; do
        echo -n "Checksum of table $database.$table: "
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "checksum table $database.$table"|awk '{print $2}'
    done < <("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "SHOW TABLES FROM $database;")
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

start_server() {
    # This function starts the server

    echo "Starting mysql server"
    pushd "$mysqldir" >/dev/null 2>&1 || exit
    ./start "${MYSQLD_OPTIONS}" >/dev/null 2>&1
    "${mysqldir}"/bin/mysqladmin ping --user=root --socket="${mysqldir}"/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Database logs: ${mysqldir}/log"
        popd >/dev/null 2>&1 || exit
        exit 1
    fi
    echo "The mysql server was started successfully"
}

run_load_tests() {
    # This function runs the load backup tests with normal options
    MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
    BACKUP_PARAMS="--core-file --lock-ddl"
    PREPARE_PARAMS="--core-file"
    RESTORE_PARAMS=""

    # Pstress options
    if [[ "$1" = "rocksdb" ]]; then
        echo "Test: Incremental Backup and Restore for rocksdb with ${load_tool}"
        tool_options="--tables 10 --records 200 --threads 10 --seconds 150 --no-encryption --engine=rocksdb"
    else
        echo "Test: Incremental Backup and Restore with ${load_tool}"
        tool_options="--tables 10 --records 200 --threads 10 --seconds 150 --no-encryption --undo-tbs-sql 0"
    fi

    initialize_db

    if [[ "$1" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="--core-file --lock-ddl --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    run_load "${tool_options}"
    take_backup
    check_tables
}

run_load_keyring_plugin_tests() {
    # This function runs the load backup tests with keyring_file plugin options
    BACKUP_PARAMS="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file --lock-ddl"
    PREPARE_PARAMS="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
    RESTORE_PARAMS="${PREPARE_PARAMS}"

    tool_options_encrypt_no_alter="--tables 10 --records 200 --threads 10 --seconds 150 --undo-tbs-sql 0 --alt-tbs-enc 0 --alter-table-encrypt 0 --no-tbs 0 --no-temp-tables 1"

    if "${mysqldir}"/bin/mysqld --version | grep "8.0" >/dev/null 2>&1 ; then
        if ${mysqldir}/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then
            # Server is MS 8.0
            MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"

            tool_options_encrypt="--tables 10 --records 200 --threads 10 --seconds 150 --undo-tbs-sql 0" # Used for pstress
        else

            # Server is PS 8.0
            MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --innodb_parallel_dblwr_encrypt --table-encryption-privilege-check=ON --innodb-default-encryption-key-id=4294967295 --max-connections=5000"

            tool_options_encrypt="--tables 10 --records 200 --threads 10 --seconds 150 --undo-tbs-sql 0" # Used for pstress
        fi
    else
        # Server is MS/PS 5.7

        if "${mysqldir}"/bin/mysqld --version | grep "MySQL Community Server" >/dev/null 2>&1 ; then
            # Server is MS 5.7
            MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"

            # Run pstress without ddl
            tool_options_encrypt="--tables 10 --records 200 --threads 10 --seconds 150 --undo-tbs-sql 0 --no-ddl"
        else

            # Server is PS 5.7 --innodb-temp-tablespace-encrypt is not GA and is deprecated
            MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-binlog --encrypt-tmp-files --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"

            # Run pstress without temp tables encryption - existing issue PXB-2534
            tool_options_encrypt="--tables 10 --records 200 --threads 10 --seconds 150 --undo-tbs-sql 0 --no-temp-tables 1"
        fi
    fi

    echo "Test: Incremental Backup and Restore for keyring_file plugin with ${load_tool}"

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

run_load_keyring_component_tests() {
    # This function runs the load backup tests with keyring_file plugin options
    BACKUP_PARAMS="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
    PREPARE_PARAMS="${BACKUP_PARAMS}"
    RESTORE_PARAMS="${BACKUP_PARAMS}"

    if "${mysqldir}"/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then
        # Server is MS 8.0
        MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"

    elif "${mysqldir}"/bin/mysqld --version | grep "8.0" >/dev/null 2>&1 ; then
        # Server is PS 8.0
        MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --innodb_parallel_dblwr_encrypt --table-encryption-privilege-check=ON --innodb-default-encryption-key-id=4294967295 --max-connections=5000"

    else
        # Server is MS/PS 5.7
        echo "Component is not supported in MS/PS 5.7"
        return
    fi

    echo "Test: Incremental Backup and Restore for keyring_file component with ${load_tool}"

    keyring_file="${mysqldir}/lib/plugin/component_keyring_file"

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

    tool_options_encrypt="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0" # Used for pstress

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

    if [[ -f "${mysqldir}"/lib/plugin/component_keyring_file.cnf ]]; then
        rm "${mysqldir}"/lib/plugin/component_keyring_file.cnf
    fi
}

run_load_kmip_component_tests() {
    # This function runs the load backup tests with keyring_kmip plugin options
    BACKUP_PARAMS="--xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
    PREPARE_PARAMS="${BACKUP_PARAMS}"
    RESTORE_PARAMS="${BACKUP_PARAMS}"

    if "${mysqldir}"/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then
        # Server is MS 8.0
        echo "MS 8.0 does not support keyring kmip for encryption, skipping keyring kmip tests"
        return

    elif "${mysqldir}"/bin/mysqld --version | grep "8.0" >/dev/null 2>&1 ; then
        # Server is PS 8.0
        MYSQLD_OPTIONS="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --innodb_parallel_dblwr_encrypt --table-encryption-privilege-check=ON --innodb-default-encryption-key-id=4294967295 --max-connections=5000"

    else
        # Server is MS/PS 5.7
        echo "Kmip Component is not supported in MS/PS 5.7"
        return
    fi

    echo "Test: Incremental Backup and Restore for keyring_kmip component with ${load_tool}"

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

    tool_options_encrypt="--tables 10 --records 200 --threads 10 --seconds 150 --undo-tbs-sql 0" # Used for pstress

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

run_crash_tests_pstress() {
    # This function crashes the server during load and then runs backup

    local test_type="$1"

    if [[ "${test_type}" = "encryption" ]]; then
        echo "Running crash tests with ${load_tool} and mysql running with encryption"
        if "${mysqldir}"/bin/mysqld --version | grep "8.0" >/dev/null 2>&1 ; then
            if ${mysqldir}/bin/mysqld --version | grep "8.0" | grep "MySQL Community Server" >/dev/null 2>&1 ; then
                # Server is MS 8.0
                MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON --max-connections=5000 --binlog-encryption"

                load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0" # Used for pstress
            else

                # Server is PS 8.0
                MYSQLD_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --innodb_parallel_dblwr_encrypt --table-encryption-privilege-check=ON --innodb-default-encryption-key-id=4294967295 --max-connections=5000"

                load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0" # Used for pstress
            fi
        else
            # Server is MS/PS 5.7

            if "${mysqldir}"/bin/mysqld --version | grep "MySQL Community Server" >/dev/null 2>&1 ; then
                # Server is MS 5.7
                MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"

                # Run pstress without ddl
                load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0 --no-ddl"
            else

                # Server is PS 5.7 --innodb-temp-tablespace-encrypt is not GA and is deprecated
                MYSQLD_OPTIONS="--log-bin=binlog --early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-binlog --encrypt-tmp-files --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"

                # Run pstress without temp tables encryption - existing issue PXB-2534
                load_options="--tables 10 --records 200 --threads 10 --seconds 50 --undo-tbs-sql 0 --no-temp-tables 1"
            fi
        fi

        BACKUP_PARAMS="--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
        PREPARE_PARAMS="${BACKUP_PARAMS}"
        PREPARE_PARAMS="${BACKUP_PARAMS}"

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

        load_options="--tables 10 --records 200 --threads 10 --seconds 150 --no-encryption --undo-tbs-sql 0"
    fi

    if [ -d "${backup_dir}" ]; then
        rm -r "${backup_dir}"
    fi
    mkdir "${backup_dir}"
    log_date=$(date +"%d_%m_%Y_%M")


    initialize_db

    if [[ "$2" = "pagetracking" ]]; then
        echo "Running test with page tracking enabled"
        BACKUP_PARAMS="${BACKUP_PARAMS} --page-tracking"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "INSTALL COMPONENT 'file://component_mysqlbackup';"
    fi

    echo "Run pstress prepare with options: ${load_options}"
    pushd "$tool_dir" >/dev/null 2>&1 || exit
    ./pstress-ps ${load_options} --prepare --logdir="${logdir}" --socket "${mysqldir}"/socket.sock >"${logdir}"/pstress_prepare.log 
    popd >/dev/null 2>&1 || exit

    run_load "${load_options} --step 2"

    echo "Taking full backup"
    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    # Save the full backup dir
    cp -pr ${backup_dir}/full ${backup_dir}/full_save

    sleep 1

    inc_num=1
    for ((i=1; i<=20; i++)); do

        if [ -d "${mysqldir}"/data_crash_save ]; then
            rm -r "${mysqldir}"/data_crash_save
        fi

        echo "Crash the mysql server"
        "${mysqldir}"/kill
        cp -pr "${mysqldir}"/data "${mysqldir}"/data_crash_save

        start_server

        run_load "${load_options} --step $(($i + 2))"

        echo "Taking incremental backup: $inc_num"
        if [[ "${inc_num}" -eq 1 ]]; then
            "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
        else
            "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/inc${inc_num} --incremental-basedir="${backup_dir}"/inc$((inc_num - 1)) -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/inc${inc_num}_backup_"${log_date}"_log
        fi
        if [ "$?" -ne 0 ]; then
            echo "ERR: Incremental Backup failed. Please check the log at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
            exit 1
        else
            echo "Inc backup was successfully created at: ${backup_dir}/inc${inc_num}. Logs available at: ${logdir}/inc${inc_num}_backup_${log_date}_log"
        fi

        # Save the incremental backup dir
        cp -pr ${backup_dir}/inc${inc_num} ${backup_dir}/inc${inc_num}_save

        let inc_num++
        sleep 2
    done

	echo "Preparing full backup"
    "${xtrabackup_dir}"/xtrabackup --prepare --apply-log-only --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi
	
    for ((i=1; i<inc_num; i++)); do

        echo "Preparing incremental backup: $i"
        if [[ "${i}" -eq "${inc_num}-1" ]]; then
            "${xtrabackup_dir}"/xtrabackup --prepare --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
        else
            "${xtrabackup_dir}"/xtrabackup --prepare --apply-log-only --target_dir="${backup_dir}"/full --incremental-dir="${backup_dir}"/inc"${i}" ${PREPARE_PARAMS} 2>"${logdir}"/prepare_inc"${i}"_backup_"${log_date}"_log
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
    "${xtrabackup_dir}"/xtrabackup --copy-back --target-dir="${backup_dir}"/full --datadir="${datadir}" ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
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

if [ "$#" -lt 1 ]; then
    echo "Usage: Please run the script with the following testsuites"
    echo "Normal_and_Encryption_tests"
    echo "Kmip_Encryption_tests"
    echo "Rocksdb_tests"
    echo "Page_Tracking_tests"
    exit 1
fi

echo "################################## Running Tests ##################################"
for tsuitelist in $*; do
    case "${tsuitelist}" in
		Normal_and_Encryption_tests)
			run_load_tests
			echo "###################################################################################"
			run_load_keyring_plugin_tests
			echo "###################################################################################"
			run_load_keyring_component_tests
			echo "###################################################################################"
			run_crash_tests_pstress "normal"
			echo "###################################################################################"
			run_crash_tests_pstress "encryption"
			echo "###################################################################################"
			;;

        Kmip_Encryption_tests)
            run_load_kmip_component_tests
            echo "###################################################################################"
            run_load_kmip_component_tests "pagetracking"
            echo "###################################################################################"
            ;;

        Rocksdb_tests)
            echo "Rocksdb Tests"
            run_load_tests "rocksdb"
            echo "###################################################################################"
            run_crash_tests_pstress "rocksdb"
            echo "###################################################################################"
            ;;

        Page_Tracking_tests)
            echo "Page Tracking Tests"
            run_load_tests "pagetracking"
            echo "###################################################################################"
            run_load_keyring_plugin_tests "pagetracking"
            echo "###################################################################################"
            run_load_keyring_component_tests "pagetracking"
            echo "###################################################################################"
            run_crash_tests_pstress "normal" "pagetracking"
            echo "###################################################################################"
            run_crash_tests_pstress "encryption" "pagetracking"
            echo "###################################################################################"
            run_crash_tests_pstress "rocksdb" "pagetracking"
            echo "###################################################################################"
            ;;
    esac
done
