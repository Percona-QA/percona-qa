#!/bin/bash

########################################################################
# Created By Manish Chawla, Percona LLC                                #
# Modified By Mohit Joshi, Percona LLC                                 #
# This script tests backup for individual tables                       #
# Usage:                                                               #
# 1. Set paths in this script:                                         #
#    xtrabackup_dir, backup_dir, mysqldir, datadir, qascripts, logdir  #
# 2. Run the script as: ./partial_backup_tests.sh                      #
# 3. Logs are available in: logdir                                     #
########################################################################

export xtrabackup_dir="$HOME/pxb-8.4/bld_8.4_debug/install/bin"
export mysqldir="$HOME/mysql-8.4/bld_8.4/install"
export datadir="${mysqldir}/data"
export backup_dir="$HOME/dbbackup_$(date +"%d_%m_%Y")"
export PATH="$PATH:$xtrabackup_dir"
export qascripts="$HOME/percona-qa"
export logdir="$HOME/backuplogs"
export mysql_random_data_load_tool="$HOME/mysql_random_data_load"
declare -A KMIP_CONFIGS=(
    # PyKMIP Docker Configuration
    ["pykmip"]="addr=127.0.0.1,image=mohitpercona/kmip:latest,port=5696,name=kmip_pykmip"

    # Hashicorp Docker Setup Configuration
    ["hashicorp"]="addr=127.0.0.1,port=5696,name=kmip_hashicorp,setup_script=hashicorp-kmip-setup.sh"

    # API Configuration
    # ["ciphertrust"]="addr=127.0.0.1,port=5696,name=kmip_ciphertrust,setup_script=setup_kmip_api.py"
)

# Set sysbench variables
num_tables=10
table_size=1000
mysql_start_timeout=60
# Setting default server_type to Percona Server
server_type=PS
server_version=$($mysqldir/bin/mysqld --version | awk -F 'Ver ' '{print $2}' | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

check_dependencies() {
    # This function checks if the required dependencies are installed

    if ! sysbench --version >/dev/null 2>&1 ; then
        echo "ERR: The sysbench tool is not installed. It is required to run load."
        exit 1
    fi

    if ! pt-table-checksum --version >/dev/null 2>&1 ; then
        echo "ERR: The percona toolkit is not installed. It is required to check the data."
        exit 1
    fi

    if [ ! -f ${mysql_random_data_load_tool} ]; then
        echo "The mysql_random_data_load tool is not installed. It is required to create the data."
        echo "Installing mysql_random_data_load tool"
        wget https://github.com/Percona-Lab/mysql_random_data_load/releases/download/v0.1.12/mysql_random_data_load_0.1.12_Linux_x86_64.tar.gz
        tar -C $HOME -xf mysql_random_data_load_0.1.12_Linux_x86_64.tar.gz
    fi
}

start_server() {
  # This function starts the server
  pkill -9 mysqld

  echo "=>Starting MySQL server"
  $mysqldir/bin/mysqld --no-defaults --basedir=$mysqldir --datadir=$datadir $MYSQLD_OPTIONS --port=21000 --socket=$mysqldir/socket.sock --plugin-dir=$mysqldir/lib/plugin --max-connections=1024 --log-error=$datadir/error.log  --general-log --log-error-verbosity=3 --core-file > /dev/null 2>&1 &
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

initialize_db() {

    local MYSQLD_OPTIONS=$1
    # This function initializes and starts mysql database
    if [ ! -d "${logdir}" ]; then
        mkdir "${logdir}"
    fi

    if [ -d $datadir ]; then
        rm -rf $datadir
    fi

    echo "=>Creating data directory"
    $mysqldir/bin/mysqld --no-defaults $MYSQLD_OPTIONS --datadir=$datadir --initialize-insecure > $mysqldir/mysql_install_db.log 2>&1
    echo "..Data directory created"
    start_server

    $mysqldir/bin/mysqladmin ping --user=root --socket=$mysqldir/socket.sock >/dev/null 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: Database could not be started in location ${mysqldir}. Please check the directory"
        exit 1
    fi

    output=$($mysqldir/bin/mysql -uroot -S$mysqldir/socket.sock -Ne "SELECT COUNT(*) FROM information_schema.engines WHERE engine='InnoDB' AND comment LIKE 'Percona%';")
    if [ "$output" -eq 1 ]; then
        server_type="PS"
        echo "Test is running against: $server_type-$server_version"
    elif [ "$output" -eq 0 ]; then
        server_type="MS"
        echo "Test is running against: $server_type-$server_version"
    else
        echo "Invalid server version!"
        exit 1
    fi

    $mysqldir/bin/mysql -uroot -S$mysqldir/socket.sock -e"CREATE DATABASE test;"
    echo "Create data using sysbench"
    if [[ "${MYSQLD_OPTIONS}" != *"encrypt"* ]]; then
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --table-size=${table_size} --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket="${mysqldir}"/socket.sock prepare >"${logdir}"/sysbench.log
    else
        # Encryption enabled
        for ((i=1; i<=num_tables; i++)); do
            echo "Creating the table sbtest$i..."
            ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE test.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ENGINE=InnoDB DEFAULT CHARSET=latin1 ENCRYPTION='Y';"
        done

        echo "Adding data in tables..."
        sysbench /usr/share/sysbench/oltp_insert.lua --tables=${num_tables} --mysql-db=test --mysql-user=root --threads=50 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=30 run >/dev/null 2>&1
    fi
}

take_partial_backup() {
    # This function takes a partial backup
    local BACKUP_PARAMS="$1"
    local PREPARE_PARAMS="$2"
    local RESTORE_PARAMS="$3"
    local TABLES_LIST="$4"

    log_date=$(date +"%d_%m_%Y_%M")

    if [ -d ${backup_dir} ]; then
        rm -r ${backup_dir}
    fi
    mkdir -p ${backup_dir}/full

    echo "Taking backup"
    "${xtrabackup_dir}"/xtrabackup --user=root --password='' --backup --target-dir="${backup_dir}"/full -S "${mysqldir}"/socket.sock --datadir="${datadir}" ${BACKUP_PARAMS} 2>"${logdir}"/full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Full Backup failed. Please check the log at: ${logdir}/full_backup_${log_date}_log"
        exit 1
    else
        echo "Full backup was successfully created at: ${backup_dir}/full. Logs available at: ${logdir}/full_backup_${log_date}_log"
    fi

    sleep 1

    echo "Preparing backup with --export option"
    "${xtrabackup_dir}"/xtrabackup --prepare --export --target_dir="${backup_dir}"/full ${PREPARE_PARAMS} 2>"${logdir}"/prepare_full_backup_"${log_date}"_log
    if [ "$?" -ne 0 ]; then
        echo "ERR: Prepare of full backup failed. Please check the log at: ${logdir}/prepare_full_backup_${log_date}_log"
        exit 1
    else
        echo "Prepare of full backup was successful. Logs available at: ${logdir}/prepare_full_backup_${log_date}_log"
    fi

    # Collect data before restore
    orig_data=$(pt-table-checksum S="${mysqldir}"/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format --no-version-check 2>/dev/null | awk '{print $4}')

    echo "Tables list to restore: ${TABLES_LIST}"
    for table in ${TABLES_LIST}; do
        echo "Restoring ${table}"
        echo "Discard tablespace of ${table}"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "ALTER TABLE test.$table DISCARD TABLESPACE;"

        echo "Copy ${table} files from backup"
        #cp -r "${backup_dir}"/full/test/${table}.* "${mysqldir}"/data/test/.
        cp -r "${backup_dir}"/full/test/${table}* "${mysqldir}"/data/test/.
        if [ "$?" -ne 0 ]; then
            echo "ERR: The ${table} files could not be copied to ${mysqldir}/data/test/ dir. The backup in ${backup_dir}/full/test does not contain the ${table} files."
            exit 1
        fi

        echo "Import tablespace of ${table}"
        "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "ALTER TABLE test.$table IMPORT TABLESPACE;"
        if [ "$?" -ne 0 ]; then
            echo "ERR: Restore of ${table} failed. Please check the database logs at: ${mysqldir}/log"
            exit 1
        else
            echo "Restore of ${table} was successful."
        fi
    done

    check_tables

    echo "Check the restored data"
    # Collect data after restore
    res_data=$(pt-table-checksum S="${mysqldir}"/socket.sock,u=root -d test --recursion-method hosts --no-check-binlog-format --no-version-check 2>/dev/null | awk '{print $4}')

    if [[ "${orig_data}" != "${res_data}" ]]; then
        echo "ERR: Data changed after restore. Original data: ${orig_data} Restored data: ${res_data}"
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

create_keyring_component_files() {
 local keyring_type="$1"
 local kmip_type="$2"
 if [ "$keyring_type" = "keyring_kmip" ]; then
    echo "Keyring type is KMIP. Taking KMIP-specific action..."

    echo '{
      "components": "file://component_keyring_kmip"
    }' > "$mysqldir/bin/mysqld.my"

    start_kmip_server "$kmip_type"
    [ -f "${HOME}/${config[cert_dir]}/component_keyring_kmip.cnf" ] && cp "${HOME}/${config[cert_dir]}/component_keyring_kmip.cnf" "$mysqldir/lib/plugin/"

  elif [ "$keyring_type" = "keyring_file" ]; then
    echo "Keyring type is file. Taking file-based action..."

    echo '{
      "components": "file://component_keyring_file"
    }' > "$mysqldir/bin/mysqld.my"

    cat > "$mysqldir/lib/plugin/component_keyring_file.cnf" <<-EOFL
    {
       "component_keyring_file_data": "${mysqldir}/keyring",
       "read_only": false
    }
EOFL
  fi
}

test_partial_table_backup() {
    # Test suite for partial table backup tests

    check_dependencies

    echo "Test: Full backup and partial table restore"
    initialize_db ""

    echo "Create a table with all data types"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE IF NOT EXISTS alltypes (a INT, b TINYINT, c SMALLINT, d MEDIUMINT, e BIGINT, f DECIMAL, g NUMERIC, h FLOAT, i REAL, j DOUBLE, k BIT(16), l DATE, m TIME, n DATETIME, o TIMESTAMP, p YEAR, q CHAR, r VARCHAR(120), s BINARY(3), t VARBINARY(3), u BLOB, v TEXT, x ENUM('1', '2', '3'), y SET('a', 'b', 'c', 'd'), z TINYBLOB, aa MEDIUMBLOB, ab LONGBLOB, ac TINYTEXT, ad MEDIUMTEXT, ae LONGTEXT, af GEOMETRY SRID 0, ag JSON);" test

    port_no=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@port;")

    echo "Add data in the alltypes table"
    ${mysql_random_data_load_tool} test alltypes 10 --user root --password '' --host=127.0.0.1 --port=${port_no} >"${logdir}"/data_load_log 2>&1
    if [ "$?" -ne 0 ]; then
        echo "ERR: The mysql_random_data_load_tool could not add data to the alltypes table. Please check the logs at: ${logdir}/data_load_log"
        exit 1
    fi

    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "UPDATE alltypes SET k = 'a', af = POINT(1,2), ag = '{\"key1\": \"value1\", \"key2\": \"value2\"}';" test

    take_partial_backup "" "" "" "sbtest1 sbtest2 alltypes"
    echo "###################################################################################"

    echo "Test: Partial backup and restore of tables using a pattern and excluding some tables"
    take_partial_backup "--tables=sbtest[1-5] --tables-exclude=sbtest10,sbtest5,sbtest4" "" "" "sbtest1 sbtest2 sbtest3"

    for table in sbtest10 sbtest5 sbtest4; do
        if [[ -f "${backup_dir}"/full/test/"${table}".ibd ]]; then
            echo "ERR: PXB took the backup of ${table} table. The ${table} table should be excluded from the backup."
            exit 1
        fi
    done
    echo "###################################################################################"

    echo "Test: Partial backup and restore of tables using a text file"
    echo "test.sbtest3">"${logdir}"/tables.txt
    echo "test.sbtest5">>"${logdir}"/tables.txt
    take_partial_backup "--tables-file=${logdir}/tables.txt" "" "" "sbtest3 sbtest5"
    echo "###################################################################################"

    echo "Test: Partial backup and restore of partitioned tables"
    echo "Create innodb partitioned tables"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE IF EXISTS sbtest1; DROP TABLE IF EXISTS sbtest2; DROP TABLE IF EXISTS sbtest3;" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest1 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY HASH(id) PARTITIONS 10;" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest2 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN (500), PARTITION p1 VALUES LESS THAN (1000), PARTITION p2 VALUES LESS THAN MAXVALUE);" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest3 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY KEY() PARTITIONS 5;" test

    echo "Add data for innodb partitioned tables"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=3 --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=5 run >/dev/null 2>&1

    take_partial_backup "--tables=sbtest1,sbtest2,sbtest3 --tables-exclude=sbtest10" "" "" "sbtest1 sbtest2 sbtest3"
}

test_partial_table_backup_encrypt() {
      echo "Testing keyring_file..."
      test_partial_table_backup_encrypted "keyring_file" "" "$feature"

      if ! source ./kmip_helper.sh; then
        echo "ERROR: Failed to load KMIP helper library"
        exit 1
      fi
      init_kmip_configs
      echo "Testing keyring_kmip with vault types..."
      for vault_type in "${!KMIP_CONFIGS[@]}"; do
        echo "Testing with $vault_type..."
        test_partial_table_backup_encrypted "keyring_kmip" "$vault_type" "$feature"
      done
}

test_partial_table_backup_encrypted() {
    local keyring_type="$1"
    local kmip_type="$2"
    # Test suite for partial table backup tests with encryption

    echo "Test suite for partial table backup tests with encryption"
    check_dependencies

    echo "Test: Full backup and partial table restore"
    if [ "$server_type" == "MS" ]; then
        server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
    elif [ "$server_type" == "PS" ]; then
        server_options="--innodb-undo-log-encrypt --innodb-redo-log-encrypt --default-table-encryption=ON --innodb_encrypt_online_alter_logs=ON --innodb_temp_tablespace_encrypt=ON --log-slave-updates --gtid-mode=ON --enforce-gtid-consistency --binlog-format=row --master_verify_checksum=ON --binlog_checksum=CRC32 --encrypt-tmp-files --innodb_sys_tablespace_encrypt --binlog-rotate-encryption-master-key-at-startup --table-encryption-privilege-check=ON"
    fi
    create_keyring_component_files $keyring_type $kmip_type
    initialize_db "${server_options} --binlog-encryption"

    echo "Create a table with all data types"
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "CREATE TABLE IF NOT EXISTS alltypes (a INT, b TINYINT, c SMALLINT, d MEDIUMINT, e BIGINT, f DECIMAL, g NUMERIC, h FLOAT, i REAL, j DOUBLE, k BIT(16), l DATE, m TIME, n DATETIME, o TIMESTAMP, p YEAR, q CHAR, r VARCHAR(120), s BINARY(3), t VARBINARY(3), u BLOB, v TEXT, x ENUM('1', '2', '3'), y SET('a', 'b', 'c', 'd'), z TINYBLOB, aa MEDIUMBLOB, ab LONGBLOB, ac TINYTEXT, ad MEDIUMTEXT, ae LONGTEXT, af GEOMETRY SRID 0, ag JSON) ENCRYPTION='Y';" test

    port_no=$("${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -Bse "select @@port;")

    echo "Add data in the alltypes table"
    ${mysql_random_data_load_tool} test alltypes 10 --user root --password '' --host=127.0.0.1 --port=${port_no} >"${logdir}"/data_load_log 2>&1
    "${mysqldir}"/bin/mysql -uroot -S"${mysqldir}"/socket.sock -e "UPDATE alltypes SET k = 'a', af = POINT(1,2), ag = '{\"key1\": \"value1\", \"key2\": \"value2\"}';" test

    if [ "$keyring_type" = "keyring_kmip" ]; then
      keyring_filename="${mysqldir}/lib/plugin/component_keyring_kmip.cnf"
    elif [ "$keyring_type" = "keyring_file" ]; then
      keyring_filename="${mysqldir}/lib/plugin/component_keyring_file.cnf"
    fi
    take_partial_backup "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--component-keyring-config=$keyring_filename  --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "sbtest1 sbtest2 alltypes"
    echo "###################################################################################"

    echo "Test: Partial backup and restore of tables using a pattern and excluding some tables"
    take_partial_backup "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --tables=sbtest[1-5] --tables-exclude=sbtest10,sbtest5,sbtest4" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "sbtest1 sbtest2 sbtest3"

    for table in sbtest10 sbtest5 sbtest4; do
        if [[ -f "${backup_dir}"/full/test/"${table}".ibd ]]; then
            echo "ERR: PXB took the backup of ${table} table. The ${table} table should be excluded from the backup."
            exit 1
        fi
    done
    echo "###################################################################################"

    echo "Test: Partial backup and restore of tables using a text file"
    echo "test.sbtest3">"${logdir}"/tables.txt
    echo "test.sbtest5">>"${logdir}"/tables.txt
    take_partial_backup "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --tables-file=${logdir}/tables.txt" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "sbtest3 sbtest5"
    echo "###################################################################################"

    echo "Test: Partial backup and restore of partitioned tables"
    echo "Create innodb partitioned tables"
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "DROP TABLE IF EXISTS sbtest1; DROP TABLE IF EXISTS sbtest2; DROP TABLE IF EXISTS sbtest3;" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest1 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY HASH(id) PARTITIONS 10;" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest2 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY RANGE(id) (PARTITION p0 VALUES LESS THAN (500), PARTITION p1 VALUES LESS THAN (1000), PARTITION p2 VALUES LESS THAN MAXVALUE);" test
    ${mysqldir}/bin/mysql -uroot -S${mysqldir}/socket.sock -e "CREATE TABLE sbtest3 (id int NOT NULL AUTO_INCREMENT, k int NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) PARTITION BY KEY() PARTITIONS 5;" test

    echo "Add data for innodb partitioned tables"
    sysbench /usr/share/sysbench/oltp_insert.lua --tables=3 --mysql-db=test --mysql-user=root --threads=100 --db-driver=mysql --mysql-socket=${mysqldir}/socket.sock --time=5 run >/dev/null 2>&1

    take_partial_backup "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin --tables=sbtest1,sbtest2,sbtest3 --tables-exclude=sbtest10" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "--component-keyring-config=$keyring_filename --xtrabackup-plugin-dir=${xtrabackup_dir}/../lib/plugin" "sbtest1 sbtest2 sbtest3"
}

cleanup() {
  echo "################################## CleanUp #######################################"
  containers_found=false
  if [ ${#KMIP_CONTAINER_NAMES[@]} -gt 0 ] 2>/dev/null; then
   get_kmip_container_names
   echo "Checking for previously started containers..."
   for name in "${KMIP_CONTAINER_NAMES[@]}"; do
      if docker ps -aq --filter "name=$name" | grep -q .; then
        containers_found=true
        break
      fi
   done
  fi

  if [[ "$containers_found" == true ]]; then
    echo "Killing previously started containers if any..."
    for name in "${KMIP_CONTAINER_NAMES[@]}"; do
        cleanup_existing_container "$name"
    done
  fi

 # Only cleanup vault directory if it exists
  if [[ -d "$HOME/vault" && -n "$HOME" ]]; then
    echo "Cleaning up vault directory..."
    sudo rm -rf "$HOME/vault"
  fi
}
trap cleanup EXIT INT TERM

echo "################################## Running Tests ##################################"
test_partial_table_backup
echo "###################################################################################"
test_partial_table_backup_encrypt
echo "###################################################################################"
