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

function run_pytests_bats() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/pytests.bats
  else
    bats $DIRNAME/pytests.bats
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

# Run clone and build here
if [[ $clone == 1 ]] ; then
  echo "Clone and Build server from repo"
  clone_and_build ${WORKDIR}
else
  echo "Skipping Clone and Build"
fi

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
run_pytests_bats
run_mysqlsh_bats
#run_mysqlx_plugin_test
