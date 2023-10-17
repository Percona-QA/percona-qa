#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# This script runs the replication tests using PXB 8.0/2.4             #
# Assumption:                                                          # 
# 1. PS and PXB are already installed using tarballs                   #
# 2. Sysbench and percona toolkit are already installed                #
# Usage:                                                               #
# 1. Set variables in this script:                                     #
#    mysql and backup, replication, sysbench variables                 #
# 2. Run the script as: ./replication_backup_tests.sh                  #
# 3. Logs are available in: logdir                                     #
########################################################################

# Set mysql and backup variables
export xtrabackup_dir="$HOME/pxb-8.0/bld_8.1.0/install/bin"
export mysqldir="$HOME/mysql-8.0/bld_8.1.0r/install"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"

# Set replication variables
replication_dir1="$HOME/replica1_dir"
replication_dir2="$HOME/replica2_dir"
mysql_tarball="$HOME/Percona-Server-8.0.34-26-Linux.x86_64.glibc2.17-minimal.tar.gz"
GTID_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"
NO_GTID_OPTIONS="--log-bin=binlog --log-slave-updates"
ENCRYPT_OPTIONS_8="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
ENCRYPT_OPTIONS_57_MS="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring"
ENCRYPT_OPTIONS_57="--early-plugin-load=keyring_file.so --keyring_file_data=${mysqldir}/keyring --innodb-encrypt-tables=ON --encrypt-binlog --encrypt-tmp-files --innodb-temp-tablespace-encrypt --innodb-encrypt-online-alter-logs=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32"

# Set sysbench variables
num_tables=10
table_size=1000

log_date=$(date +"%d_%m_%Y_%M")

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
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1
    fi
}

replicate_primary() {
    # This function replicates the primary using the backup of primary/replica
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local RESTORE_PARAMS="$3"
    local MYSQLD_OPTIONS="$4"

    if [[ -d "${replication_dir1}" ]] || [[ -d "${replication_dir2}" ]]; then
        cleanup
    fi

    if [[ -d "${backup_dir}" ]]; then
        rm -r ${backup_dir}
    fi
    mkdir -p "${backup_dir}"/full

    echo "Test: Create a replica from backup of primary"
    mkdir ${replication_dir1}
    cp -R $HOME/mysql-8.0/bld_8.1.0r/install/* "${replication_dir1}"
    rm -rf ${replication_dir1}/data

    echo "Run a load on primary"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=20 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=30 run >/dev/null 2>&1 &

    echo "Taking full backup"
    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    sleep 1

    echo "Preparing full backup"
    "${xtrabackup_dir}"/xtrabackup --prepare --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    echo "Restoring full backup to replica"
    "${xtrabackup_dir}"/xtrabackup --copy-back --target-dir="${backup_dir}"/full --datadir="${replication_dir1}"/data ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
        exit 1
    else
        echo "Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
    fi

    if [[ "${MYSQLD_OPTIONS}" = *"keyring_file"* ]]; then
        cp "${mysqldir}"/keyring "${replication_dir1}"
        rep_mysqld_options=${MYSQLD_OPTIONS//--keyring_file_data=${mysqldir}/--keyring_file_data=${replication_dir1}}
    else
        rep_mysqld_options="${MYSQLD_OPTIONS}"
    fi
    echo "Start the replica server"
    echo "${replication_dir1}/bin/mysqld --no-defaults --core-file --basedir=${replication_dir1} --tmpdir=${replication_dir1}/data --datadir=${replication_dir1}/data --socket=${replication_dir1}/socket_rep1.sock --port=18615 --log-error=${replication_dir1}/master.err --server-id=102 --report-host=127.0.0.1 --report-port=18615 ${rep_mysqld_options}"
    "${replication_dir1}"/bin/mysqld --no-defaults --core-file --basedir=${replication_dir1} --tmpdir=${replication_dir1}/data --datadir=${replication_dir1}/data --socket=${replication_dir1}/socket_rep1.sock --port=18615 --log-error=${replication_dir1}/master.err --server-id=102 --report-host=127.0.0.1 --report-port=18615 ${rep_mysqld_options} 2>&1 &
    for ((i=1; i<=30; i++)); do
        if ! "${replication_dir1}"/bin/mysqladmin ping --user=root --socket="${replication_dir1}"/socket_rep1.sock >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ "$i" -eq 30 ]]; then
            echo "ERR: The replica server failed to start. Please check the log at: ${replication_dir1}/master.err"
            exit 1
        fi
    done

    echo "Configure and start the replication"
    #xtrabackup_bin_pos=$(awk '{print $3}' "${backup_dir}"/full/xtrabackup_binlog_info)
    mysql_maj_version=$("${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -Bse "select @@version;"|cut -f1 -d.)
    mysql_min_version=$("${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -Bse "select @@version;"|cut -f3 -d.|cut -f1 -d-)

    gtid_execute=$("${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -Bse "select @@GLOBAL.GTID_EXECUTED;")
    if [[ "${mysql_maj_version}" -eq 5 ]] && [[ -n "${gtid_execute}" ]]; then
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "RESET MASTER;"
    fi

    master_port_no=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@port;")

    if [[ "${MYSQLD_OPTIONS}" = *"gtid-mode=ON"* ]]; then
        xtrabackup_bin_pos=$(awk '{print $3}' "${backup_dir}"/full/xtrabackup_binlog_info)
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "SET GLOBAL gtid_purged='$xtrabackup_bin_pos';"
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "CHANGE MASTER TO MASTER_HOST='localhost', MASTER_USER='root', MASTER_PORT=${master_port_no}, MASTER_AUTO_POSITION=1;"
    else
        xtrabackup_bin_log=$(awk '{print $1}' "${backup_dir}"/full/xtrabackup_binlog_info)
        xtrabackup_bin_pos=$(awk '{print $2}' "${backup_dir}"/full/xtrabackup_binlog_info)
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "CHANGE MASTER TO MASTER_HOST='localhost', MASTER_USER='root', MASTER_PORT=${master_port_no}, MASTER_LOG_FILE='$xtrabackup_bin_log', MASTER_LOG_POS=$xtrabackup_bin_pos;"
    fi

    echo "Replication status:"
    if [[ "${mysql_maj_version}" -eq 8 ]] && [[ "${mysql_min_version}" -ge 22 ]]; then
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "START REPLICA;"
        replication_status=$("${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "SHOW REPLICA STATUS \G")
        echo "${replication_status}"
        io_status=$(echo "${replication_status}" | grep "Replica_IO_Running" | awk '{print $2}')
        sql_running=$(echo "${replication_status}" | grep -m 1 "Replica_SQL_Running" | awk '{print $2}')
    else
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "START SLAVE;"
        replication_status=$("${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "SHOW SLAVE STATUS \G")
        echo "${replication_status}"
        io_status=$(echo "${replication_status}" | grep "Slave_IO_Running" | awk '{print $2}')
        sql_running=$(echo "${replication_status}" | grep -m 1 "Slave_SQL_Running" | awk '{print $2}')
    fi

    if [[ "${io_status}" = "Yes" ]] && [[ "${sql_running}" = "Yes" ]]; then
        echo "Replication is successful on replica"
    else
        echo "ERR: Replication was not successful. Please check the log at: ${replication_dir1}/master.err"
        exit 1
    fi

    check_tables "${replication_dir1}"

    echo "Run pt-table-checksum on primary"
    pt-table-checksum S="${mysqldir}"/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format --no-version-check 2>/dev/null

    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    echo "###################################################################################"

    echo "Test: Create a replica from backup of replica"
    echo "Extract the mysql tarball in replication directory"

    log_date=$(date +"%d_%m_%Y_%M")
    mkdir $replication_dir2
    cp -R $HOME/mysql-8.0/bld_8.1.0r/install/* "${replication_dir2}"
    rm -rf ${replication_dir2}/data

    if [[ "${MYSQLD_OPTIONS}" = *"keyring_file"* ]]; then
        BACKUP_PARAMS=${BACKUP_PARAMS//--keyring_file_data=${mysqldir}/--keyring_file_data=${replication_dir1}}
        PREPARE_PARAMS=${PREPARE_PARAMS//--keyring_file_data=${mysqldir}/--keyring_file_data=${replication_dir1}}
    fi
    echo "Run a load on primary"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=20 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=20 run >/dev/null 2>&1 &

    slave_parallel_workers=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@slave_parallel_workers;")

    if [[ "${MYSQLD_OPTIONS}" != *"gtid-mode=ON"* ]] && [[ "${slave_parallel_workers}" -ge 2 ]]; then
        echo "Taking full backup with --slave-info --safe-slave-backup"
        "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${replication_dir1}"/socket_rep1.sock --datadir="${replication_dir1}"/data --slave-info --safe-slave-backup ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    else
        echo "Taking full backup with --slave-info"
        "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${replication_dir1}"/socket_rep1.sock --datadir="${replication_dir1}"/data --slave-info ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    fi
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    sleep 1

    echo "Preparing full backup"
    "${xtrabackup_dir}"/xtrabackup --prepare --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    echo "Restoring full backup to new replica"
    "${xtrabackup_dir}"/xtrabackup --copy-back --target-dir="${backup_dir}"/full --datadir="${replication_dir2}"/data ${RESTORE_PARAMS} 2>"${logdir}"/res_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Restore of full backup failed. Please check the log at: ${logdir}/res_backup_${log_date}_log"
        exit 1
    else
        echo "Restore of full backup was successful. Logs available at: ${logdir}/res_backup_${log_date}_log"
    fi

    if [[ "${MYSQLD_OPTIONS}" = *"keyring_file"* ]]; then
        cp "${replication_dir1}"/keyring "${replication_dir2}"
        rep_mysqld_options=${MYSQLD_OPTIONS//--keyring_file_data=${mysqldir}/--keyring_file_data=${replication_dir2}}
    else
        rep_mysqld_options="${MYSQLD_OPTIONS}"
    fi

    echo "Start the replica server --skip-slave-start --server-id=103"
    echo "${replication_dir2}/bin/mysqld --no-defaults --core-file --basedir=${replication_dir2} --tmpdir=${replication_dir2}/data --datadir=${replication_dir2}/data --socket=${replication_dir2}/socket_rep2.sock --port=18620 --log-error=${replication_dir2}/master.err --skip-slave-start --server-id=103 --report-host=127.0.0.1 --report-port=18620 ${rep_mysqld_options}"
    "${replication_dir2}"/bin/mysqld --no-defaults --core-file --basedir=${replication_dir2} --tmpdir=${replication_dir2}/data --datadir=${replication_dir2}/data --socket=${replication_dir2}/socket_rep2.sock --port=18620 --log-error=${replication_dir2}/master.err --skip-slave-start --server-id=103 --report-host=127.0.0.1 --report-port=18620 ${rep_mysqld_options} 2>&1 &
    for ((j=1; j<=30; j++)); do
        if ! "${replication_dir2}"/bin/mysqladmin ping --user=root --socket="${replication_dir2}"/socket_rep2.sock >/dev/null 2>&1; then
            sleep 1
        else
            break
        fi

        if [[ "$j" -eq 30 ]]; then
            echo "ERR: The replica server failed to start. Please check the log at: ${replication_dir2}/master.err"
            exit 1
        fi
    done

    "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';"

    echo "Configure and start the replication"
    mysql_maj_version=$("${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -Bse "select @@version;"|cut -f1 -d.)
    mysql_min_version=$("${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -Bse "select @@version;"|cut -f3 -d.|cut -f1 -d-)

    gtid_execute=$("${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -Bse "select @@GLOBAL.GTID_EXECUTED;")
    if [[ "${mysql_maj_version}" -eq 5 ]] && [[ -n "${gtid_execute}" ]]; then
        echo "RESET MASTER in 5.7"
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "RESET MASTER;"
    elif [[ "${mysql_maj_version}" -eq 8 ]] && [[ "${mysql_min_version}" -ge 22 ]]; then
        echo "RESET REPLICA in ${mysql_maj_version}.0.${mysql_min_version}"
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "RESET REPLICA;"
    elif [[ "${mysql_maj_version}" -eq 8 ]] && [[ "${mysql_min_version}" -lt 22 ]]; then
        echo "RESET SLAVE in ${mysql_maj_version}.0.${mysql_min_version}"
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "RESET SLAVE;"
    fi

    sleep 2
    master_port_no=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@port;")

    if [[ "${MYSQLD_OPTIONS}" != *"gtid-mode=ON"* ]]; then
        xtrabackup_replica_info=$(grep "CHANGE MASTER TO" "${backup_dir}"/full/xtrabackup_slave_info|sed 's/;//g')
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "$xtrabackup_replica_info, MASTER_HOST='localhost', MASTER_USER='root', MASTER_PORT=${master_port_no};"
        if [ "$?" -ne 0 ]; then
            echo "ERR: The primary information could not be set in the replica2. Please check the log at: ${replication_dir2}/master.err"
            exit 1
        fi
    elif [[ "${mysql_maj_version}" -eq 5 ]]; then
        gtid_purged_sql=$(head -1 "${backup_dir}"/full/xtrabackup_slave_info)
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "$gtid_purged_sql"
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "CHANGE MASTER TO MASTER_HOST='localhost', MASTER_USER='root', MASTER_PORT=${master_port_no}, MASTER_AUTO_POSITION=1;"
        if [ "$?" -ne 0 ]; then
            echo "ERR: The primary information could not be set in the replica2. Please check the log at: ${replication_dir2}/master.err"
            exit 1
        fi
    fi

    echo "Replication status:"
    if [[ "${mysql_maj_version}" -eq 8 ]] && [[ "${mysql_min_version}" -ge 22 ]]; then
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "START REPLICA;"
        sleep 2
        replication_status=$("${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "SHOW REPLICA STATUS \G")
        echo "${replication_status}"
        io_status=$(echo "${replication_status}" | grep "Replica_IO_Running" | awk '{print $2}')
        sql_running=$(echo "${replication_status}" | grep -m 1 "Replica_SQL_Running" | awk '{print $2}')
    else
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "START SLAVE;"
        sleep 2
        replication_status=$("${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "SHOW SLAVE STATUS \G")
        echo "${replication_status}"
        io_status=$(echo "${replication_status}" | grep "Slave_IO_Running" | awk '{print $2}')
        sql_running=$(echo "${replication_status}" | grep -m 1 "Slave_SQL_Running" | awk '{print $2}')
    fi

    if [[ "${io_status}" = "Yes" ]] && [[ "${sql_running}" = "Yes" ]]; then
        echo "Replication is successful on replica"
    else
        echo "ERR: Replication was not successful. Please check the log at: ${replication_dir2}/master.err"
        exit 1
    fi

    check_tables "${replication_dir2}"

    echo "Run pt-table-checksum on primary"
    pt-table-checksum S="${mysqldir}"/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format --no-version-check 2>/dev/null

}

cleanup() {
    # This function cleans all replica directories

    if [[ -d "${replication_dir1}" ]]; then
        echo "Removing ${replication_dir1}"
        "${replication_dir1}"/bin/mysql -uroot -S "${replication_dir1}"/socket_rep1.sock -e "SHUTDOWN" > /dev/null 2>&1
        sleep 1
        rm -r "${replication_dir1}"
    fi

    if [[ -d "${replication_dir2}" ]]; then
        echo "Removing ${replication_dir2}"
        "${replication_dir2}"/bin/mysql -uroot -S "${replication_dir2}"/socket_rep2.sock -e "SHUTDOWN" > /dev/null 2>&1
        sleep 1
        rm -r "${replication_dir2}"
    fi
}

check_tables() {
    # This function checks all the tables in the test database
    local mysql_dir="$1"
    if [ "$mysql_dir" == "$replication_dir1" ]; then
        socket=$mysql_dir/socket_rep1.sock
     elif [ "$mysql_dir" == "$replication_dir2" ]; then
         socket=$mysql_dir/socket_rep2.sock
     else
         socket=$mysql_dir/socket.sock
     fi

    echo "Check the table status"
    check_err=0

    while read table; do
        echo "Checking table $table ..."
        if ! table_status=$("${mysql_dir}"/bin/mysql -uroot -S$socket -Bse "CHECK TABLE test.$table"|cut -f4-); then
            echo "ERR: CHECK TABLE test.$table query failed"
            # Check if database went down
            if ! "${mysql_dir}"/bin/mysqladmin ping --user=root --socket=$socket >/dev/null 2>&1; then
                echo "ERR: The database has gone down due to corruption in table test.$table"
                exit 1
            fi
        fi

        if [[ "$table_status" != "OK" ]]; then
            echo "ERR: CHECK TABLE test.$table query displayed the table status as '$table_status'"
            check_err=1
        fi
    done < <("${mysql_dir}"/bin/mysql -uroot -S$socket -Bse "SHOW TABLES FROM test;")

    # Check if database went down
    if ! "${mysql_dir}"/bin/mysqladmin ping --user=root --socket=$socket >/dev/null 2>&1; then
        echo "ERR: The database has gone down due to corruption, the restore was unsuccessful"
        exit 1
    fi

    if [[ "$check_err" -eq 0 ]]; then
        echo "All innodb tables status: OK"
    else
        echo "After restore, some tables may be corrupt, check table status is not OK"
    fi
}

echo "################################## Running Test ##################################"
check_dependencies
echo "Test: Replication with gtid options and multithreaded replica"
initialize_db "${GTID_OPTIONS} --slave-parallel-workers=4"
replicate_primary "" "" "" "${GTID_OPTIONS} --slave-parallel-workers=4"
echo "###################################################################################"

echo "Test: Replication with gtid options and single threaded replica"
if "${xtrabackup_dir}"/xtrabackup --version 2>&1 | grep "8.0" >/dev/null 2>&1 ; then
    initialize_db "${GTID_OPTIONS} --slave-parallel-workers=1"
    replicate_primary "" "" "" "${GTID_OPTIONS} --slave-parallel-workers=1"
else
    initialize_db "${GTID_OPTIONS} --slave-parallel-workers=0"
    replicate_primary "" "" "" "${GTID_OPTIONS} --slave-parallel-workers=0"
fi
echo "###################################################################################"

echo "Test: Replication without gtid options and multithreaded replica"
initialize_db "${NO_GTID_OPTIONS} --slave-parallel-workers=4"
replicate_primary "" "" "" "${NO_GTID_OPTIONS} --slave-parallel-workers=4"
echo "###################################################################################"

echo "Test: Replication without gtid options and single threaded replica"
if "${xtrabackup_dir}"/xtrabackup --version 2>&1 | grep "8.0" >/dev/null 2>&1 ; then
    initialize_db "${NO_GTID_OPTIONS} --slave-parallel-workers=0"
    replicate_primary "" "" "" "${NO_GTID_OPTIONS} --slave-parallel-workers=0"
else
    initialize_db "${NO_GTID_OPTIONS} --slave-parallel-workers=0"
    replicate_primary "" "" "" "${NO_GTID_OPTIONS} --slave-parallel-workers=0"
fi
echo "###################################################################################"

if "${xtrabackup_dir}"/xtrabackup --version 2>&1 | grep "8.0" >/dev/null 2>&1 ; then
    echo "Test: Replication with gtid options and encryption"
    initialize_db "${GTID_OPTIONS} ${ENCRYPT_OPTIONS_8}"
    replicate_primary "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${GTID_OPTIONS} ${ENCRYPT_OPTIONS_8}"
    echo "###################################################################################"

    echo "Test: Replication without gtid options and with encryption"
    initialize_db "${NO_GTID_OPTIONS} ${ENCRYPT_OPTIONS_8}"
    replicate_primary "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${NO_GTID_OPTIONS} ${ENCRYPT_OPTIONS_8}"
    echo "###################################################################################"
else
    echo "Test: Replication with gtid options and encryption"
    initialize_db "${GTID_OPTIONS} ${ENCRYPT_OPTIONS_57}"
    replicate_primary "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${GTID_OPTIONS} ${ENCRYPT_OPTIONS_57}"
    echo "###################################################################################"

    echo "Test: Replication without gtid options and with encryption"
    initialize_db "${NO_GTID_OPTIONS} ${ENCRYPT_OPTIONS_57}"
    replicate_primary "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--keyring_file_data=${mysqldir}/keyring --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "${NO_GTID_OPTIONS} ${ENCRYPT_OPTIONS_57}"
    echo "###################################################################################"
fi
