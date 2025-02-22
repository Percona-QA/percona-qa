#!/bin/bash

#####################################################################
# This script is written to test different lock-ddl modes in PXB    #
# Created by: Mohit Joshi                                           #
# Creation date: 13-Sep-2024                                        #
#####################################################################

# Set script variables
export xtrabackup_dir="$HOME/pxb-9.1/bld_9.1_pro/install/bin"
export mysqldir="$HOME/mysql-9.1/bld_9.1/install"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export logdir="$HOME/backuplogs"
export mysql_start_timeout=60

# Set tool variables
load_tool="pstress" # Set value as pstress/sysbench
num_tables=20 # Used for Sysbench
table_size=1000 # Used for Sysbench
tool_dir="$HOME/pstress_9.1/src" # pstress dir

if [ "$#" -lt 1 ]; then
    echo "This script tests different lock_ddl modes while PXB takes backup"
    echo "Usage: "
    echo "1. Set paths in this script for"
    echo "   xtrabackup_dir, backup_dir, mysqldir, datadir, logdir, tool_dir"
    echo "2. Run the script as: $0 <Test Suite>"
    echo "   Test Suites: "
    echo "   Normal_and_Encryption_tests"
    exit 1

    echo "Example: ./$0 Normal_and_Encryption_tests"
fi

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

  # Create data using sysbench
  if [[ "${load_tool}" = "sysbench" ]]; then
    if [[ "${MYSQLD_OPTIONS}" != *"keyring"* ]]; then
      sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=10 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock prepare >"${logdir}"/sysbench.log
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
    ./pstress-ps ${tool_options} --rotate-master-key 0 --logdir=${logdir}/pstress --socket ${mysqldir}/socket.sock  > $logdir/pstress/pstress.log &
    popd >/dev/null 2>&1 || exit
    sleep 2
  else
    echo "Run sysbench"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=10 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock --time=60 run >>"${logdir}"/sysbench.log &
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


run_crash_tests_pstress() {
    # This function crashes the server during load and then runs backup
    local test_type="$1"
    local lock_type="$2"

    if [[ "${test_type}" = "encryption" ]]; then
      echo "Running crash tests with ${load_tool} and mysql running with encryption"
      MYSQLD_OPTIONS="--default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --table-encryption-privilege-check=ON --max-connections=5000"
      load_options="--tables $num_tables --records $table_size --no-temp-tables --rotate-master-key 0 --alter-table-encrypt 5 --alt-tbs-enc 5 --drop-column 5 --add-column 5 --drop-index 5 --add-index 5 --rename-column 5 --rename-index 5 --threads 5 --seconds 120 --undo-tbs-sql 50 --no-select" # Used for pstress
      BACKUP_PARAMS="--lock-ddl=$lock_type --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --core-file"
      PREPARE_PARAMS="${BACKUP_PARAMS} --component-keyring-config=${mysqldir}/lib/plugin/component_keyring_file.cnf"
      RESTORE_PARAMS="${BACKUP_PARAMS}"
    else
      echo "Running crash tests with ${load_tool}"
      MYSQLD_OPTIONS="--log-bin=binlog --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --max-connections=5000"
      BACKUP_PARAMS="--core-file --lock-ddl=$lock_type"
      PREPARE_PARAMS="--core-file"
      RESTORE_PARAMS=""
      load_options="--tables $num_tables --records $table_size --no-temp-tables --drop-column 10 --add-column 10 --drop-index 10 --add-index 10 --rename-column 10 --rename-index 10 --threads 5 --seconds 120 --undo-tbs-sql 50 --no-encryption --no-select"
    fi

    if [ -d "${backup_dir}" ]; then
        rm -r "${backup_dir}"
    fi
    mkdir "${backup_dir}"
    log_date=$(date +"%d_%m_%Y_%M")

    cleanup
    create_keyring_component_files
    initialize_db

    if [ $load_tool == "pstress" ]; then
        echo "=>Run pstress to prepare metadata: ${load_options}"
        pushd "$tool_dir" >/dev/null 2>&1 || exit
        ./pstress-ps ${load_options} --prepare --no-temp-tables --exact-initial-records --logdir=${logdir}/pstress --socket ${mysqldir}/socket.sock >"${logdir}"/pstress/pstress_prepare.log
        popd >/dev/null 2>&1 || exit
        echo "..Metadata created"
        run_load "${load_options} --step 2"
    fi

    echo "=>Taking full backup"
    rr "${xtrabackup_dir}"/xtrabackup --no-defaults --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
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
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_backup_${log_date}_log
      else
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/inc$((inc_num - 1)) -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_backup_${log_date}_log
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

    if [ -d ${mysqldir}/data_crash_save2 ]; then
        rm -r ${mysqldir}/data_crash_save2
    fi

    echo "Crash the mysql server"
    {  kill -9 $MPID && wait $MPID; } 2>/dev/null
    cp -pr ${mysqldir}/data ${mysqldir}/data_crash_save2
    start_server
    run_load "${load_options} --step 4"

    for ((inc_num=5;inc_num<9;inc_num++)); do
      echo "Taking incremental backup: $inc_num"
      if [ ${inc_num} -eq 1 ]; then
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/full -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS} 2>${logdir}/inc${inc_num}_${i}_backup_${log_date}_log
      else
        rr ${xtrabackup_dir}/xtrabackup --no-defaults --user=root --password='' --backup --target-dir=${backup_dir}/inc${inc_num} --incremental-basedir=${backup_dir}/inc$((inc_num - 1)) -S ${mysqldir}/socket.sock --datadir=${datadir} ${BACKUP_PARAMS}  2>${logdir}/inc${inc_num}_backup_${log_date}_log
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
          rr ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc${i} ${PREPARE_PARAMS} 2>${logdir}/prepare_inc${i}_backup_${log_date}_log
        else
          rr ${xtrabackup_dir}/xtrabackup --no-defaults --prepare --apply-log-only --target_dir=${backup_dir}/full --incremental-dir=${backup_dir}/inc${i} ${PREPARE_PARAMS} 2>${logdir}/prepare_inc${i}_backup_${log_date}_log
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

create_keyring_component_files() {
    echo "Create global manifest file"
    cat <<-EOF >${mysqldir}/bin/mysqld.my
{
"components": "file://component_keyring_file"
}
EOF

    if [[ ! -f $mysqldir/bin/mysqld.my ]]; then
        echo "ERR: The global manifest could not be created in $mysqldir/bin/mysqld.my"
        exit 1
    fi

    echo "Create global configuration file"
    cat <<-EOF >$mysqldir/lib/plugin/component_keyring_file.cnf
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
      echo "###################################################################################"
      echo "Running combination: Tables=unencrypted; Lock_ddl=reduced"
      run_crash_tests_pstress "normal" "reduced"
      echo "###################################################################################"
      echo "Running combination: Tables=encrypted; Lock_ddl=reduced"
      run_crash_tests_pstress "encryption" "reduced"
      echo "###################################################################################"
      echo "Running combination: Tables=unencrypted; Lock_ddl=on"
      run_crash_tests_pstress "normal" "on"
      echo "Running combination: Tables=encrypted; Lock_ddl=on"
      echo "###################################################################################"
      run_crash_tests_pstress "encryption" "on"
      ;;
  esac
done

