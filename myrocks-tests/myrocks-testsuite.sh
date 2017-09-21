#!/bin/bash

# Created by Shahriyar Rzayev from Percona

WORKDIR="${PWD}"
DIRNAME=$(dirname "$0")

# Preparing test env

function clone_and_build() {
  git clone --recursive --depth=1 https://github.com/percona/percona-server.git -b 5.7 PS-5.7-trunk
  cd $1/PS-5.7-trunk
  # from percona-qa repo
  ~/percona-qa/build_5.x_debug.sh
}

function run_startup() {
  cd $1
  # from percona-qa repo
  ~/percona-qa/startup.sh
}

function start_server() {
  cd $1
  ./start
}

function execute_sql() {
  # General function to pass sql statement to mysql client
    conn_string="$(cat $1/cl_noprompt)"
    ${conn_string} -e "$2"
}

function run_generated_columns_test() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/generated_columns.bats
  else
    bats $DIRNAME/generated_columns.bats
  fi
}

function run_json_test() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/json.bats
  else
    bats $DIRNAME/json.bats
  fi
}

function install_mysql_connector() {
  # Downloading rpm package for CentOS 7
  # For now installing it globally
  # TODO: Install this package inside Python virtualenv to not affect whole system globally...
  IF_INSTALLED=$(rpm -qa | grep mysql-connector-python-8.0)
  if [ -z $IF_INSTALLED ] ; then
    wget https://dev.mysql.com/get/Downloads/Connector-Python/mysql-connector-python-8.0.4-0.1.dmr.el7.x86_64.rpm
    sudo yum install -y mysql-connector-python-8.0.4-0.1.dmr.el7.x86_64.rpm
  else
    echo "Already Installed"
  fi
}

function install_mysql_shell() {
  # Downloading rpm package for CentOS 7
  IF_INSTALLED=$(rpm -qa | grep mysql-shell-8.0)
  if [ -z $IF_INSTALLED ] ; then
    wget https://dev.mysql.com/get/Downloads/MySQL-Shell/mysql-shell-8.0.0-0.1.dmr.el7.x86_64.rpm
    sudo yum install -y mysql-shell-8.0.0-0.1.dmr.el7.x86_64.rpm
  else
    echo "Already Installed"
  fi

}


function run_mysqlx_plugin_test() {
  # not used
  python -m pytest -vvv $DIRNAME/myrocks_mysqlx_plugin_test/test_module01.py
}

function run_x_plugin_bats() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/x_plugin.bats
  else
    bats $DIRNAME/x_plugin.bats
  fi
}

function run_mysqlsh_bats() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/mysqlsh.bats
  else
    bats $DIRNAME/mysqlsh.bats
  fi
}

function run_lock_in_share_bats() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/lock_in_share.bats
  else
    bats $DIRNAME/lock_in_share.bats
  fi
}

function run_rocksdb_bulk_load_bats() {
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/rocksdb_bulk_load.bats
  else
    bats $DIRNAME/rocksdb_bulk_load.bats
  fi
}

function run_mysqldump_bats() {
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/mysqldump.bats
  else
    bats $DIRNAME/mysqldump.bats
  fi
}

function clone_the_test_db() {
  git clone https://github.com/datacharmer/test_db.git
}

function import_test_db() {
  conn_string="$(cat $1/cl_noprompt_nobinary)"
  cd $1/test_db
  ${conn_string} < employees.sql
  cd $1
}

# Run clone and build here
if [[ $clone == 1 ]] ; then
  echo "Clone and Build server from repo"
  clone_and_build ${WORKDIR}
else
  echo "Skipping Clone and Build"
fi

function create_mysqldump_command() {
  source ${DIRNAME}/mysqldump.sh ${BASEDIR}
  result=$(generate_mysqldump_command ${BASEDIR})
  MYSQLDUMP="$result employees salaries1 salaries2 salaries3"
  echo ${MYSQLDUMP}
}

# Get BASEDIR here
BASEDIR=$(ls -1td ${WORKDIR}/PS* | grep -v ".tar" | grep PS[0-9])

# Run startup.sh here
echo "Running startup.sh from percona-qa"
run_startup ${BASEDIR}

# Start server here
echo "Starting Server!"
start_server ${BASEDIR}

# Create sample database here
echo "Creating sample database"
DB="create database generated_columns_test"
execute_sql ${BASEDIR} "${DB}"

# Create sample table here
echo "Creating sample table"
TABLE="CREATE TABLE generated_columns_test.sbtest1 (
  id int(11) NOT NULL AUTO_INCREMENT,
  k int(11) NOT NULL DEFAULT '0',
  c char(120) NOT NULL DEFAULT '',
  pad char(60) NOT NULL DEFAULT '',
  PRIMARY KEY (id)
) ENGINE=InnoDB"
execute_sql ${BASEDIR} "${TABLE}"

# Altering table engine to MyRocks here
echo "Altering table engine"
ALTER="alter table generated_columns_test.sbtest1 engine=rocksdb"
execute_sql ${BASEDIR} "${ALTER}"

# Calling generated_columns.bats file here
echo "Running generated_columns.bats"
run_generated_columns_test

# Calling json.bats file here
echo "Running json.bats"
run_json_test

# Installing mysql-connector-python
echo "Installing mysql-connector-python"
install_mysql_connector

# Installing mysql-shell
echo "Installing mysql-shell"
install_mysql_shell

# Installing mysqlx plugin
echo "Installing mysqlx plugin"
MYSQLX="INSTALL PLUGIN mysqlx SONAME 'mysqlx.so'"
execute_sql ${BASEDIR} "${MYSQLX}"

# Creating user for X Plugin tests
echo "Creating sample user"
USER="create user bakux@localhost identified by 'Baku12345'"
execute_sql ${BASEDIR} "${USER}"

# Giving "all" grants for new user
echo "Granting sample user"
GRANT="grant all on *.* to bakux@localhost"
execute_sql ${BASEDIR} "${GRANT}"

# Calling myrocks_mysqlx_plugin.py file here
echo "#Running X Plugin tests#"
run_x_plugin_bats

echo "#Running mysqlsh tests#"
run_mysqlsh_bats
#run_mysqlx_plugin_test

echo "#Running lock in share mode, Gap locks detection etc. tests#"
run_lock_in_share_bats

echo "Getting sample test db repo"
clone_the_test_db

echo "Importing sample test db"
import_test_db ${BASEDIR}

echo "#Running bulk load tests#"
run_rocksdb_bulk_load_bats

echo "################################################################"
echo "Actions to test mysqldump"
echo "Altering employees.salaries engine to innodb"
ALTER_SALARIES="alter table employees.salaries engine=innodb"
execute_sql ${BASEDIR} "${ALTER_SALARIES}"

echo "Running DROP TABLE IF EXISTS"
DROP1="drop table if exists employees.salaries1"
DROP2="drop table if exists employees.salaries2"
DROP3="drop table if exists employees.salaries3"
execute_sql ${BASEDIR} "${DROP1}"
execute_sql ${BASEDIR} "${DROP2}"
execute_sql ${BASEDIR} "${DROP3}"

echo "Creating salaries1 from salaries"
CREATE_SALARIES1="create table employees.salaries1 like employees.salaries"
execute_sql ${BASEDIR} "${CREATE_SALARIES1}"

echo "Creating salaries2 from salaries"
CREATE_SALARIES2="create table employees.salaries2 like employees.salaries"
execute_sql ${BASEDIR} "${CREATE_SALARIES2}"

echo "Creating salaries3 from salaries"
CREATE_SALARIES3="create table employees.salaries3 like employees.salaries"
execute_sql ${BASEDIR} "${CREATE_SALARIES3}"

echo "Altering engine employees.salaries2 to RocksDB"
ALTER_ENG_ROCKS="alter table employees.salaries2 engine=rocksdb"
execute_sql ${BASEDIR} "${ALTER_ENG_ROCKS}"

echo "Altering engine employees.salaries3 to TokuDB"
ALTER_ENG_TOKU="alter table employees.salaries3 engine=tokudb"
execute_sql ${BASEDIR} "${ALTER_ENG_TOKU}"

echo "Inserting data to employees.salaries1"
INSERT1="insert into employees.salaries1 select * from employees.salaries where emp_no < 11000"
execute_sql ${BASEDIR} "${INSERT1}"

echo "Inserting data to employees.salaries2"
INSERT2="insert into employees.salaries2 select * from employees.salaries where emp_no < 11000"
execute_sql ${BASEDIR} "${INSERT2}"

echo "Inserting data to employees.salaries3"
INSERT3="insert into employees.salaries3 select * from employees.salaries where emp_no < 11000"
execute_sql ${BASEDIR} "${INSERT3}"

echo "Taking backup using mysqldump without any option"
# Call create_mysqldump_command function here
CMD=$(create_mysqldump_command)
$(${CMD} > ${WORKDIR}/dump1.sql)

echo "Taking backup using mysqldump with --order-by-primary-desc=true"
$(${CMD} --order-by-primary-desc=true > ${WORKDIR}/dump2.sql)

# Changing dir
cd ${WORKDIR}
#

echo "Running mysqldump.bats"
run_mysqldump_bats

# Importing dump here
echo "Importing dump2.sql here"
conn_string="$(cat ${BASEDIR}/cl_noprompt_nobinary)"
$(${conn_string} < ${WORKDIR}/dump2.sql)
