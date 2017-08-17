#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

WORKDIR="${PWD}"
DIRNAME="$BATS_TEST_DIRNAME"
DIRNAME=$(dirname "$0")

# Preparing test env

function clone_and_build() {
  git clone --recursive --depth=1 https://github.com/percona/percona-server.git -b 5.7 PS-5.7-trunk
  cd $1/PS-5.7-trunk
  ~/percona-qa/build_5.x_debug.sh
}

function run_startup() {
  cd $1/$2
  ~/percona-qa/startup.sh
}

function start_server() {
  $1/$2/start
}

function execute_sql() {
  # General function to pass sql statement to mysql client
   $1/$2/cl -e "$3"
}

# Run clone and build here
echo "Cloning and Building server from repo"
#clone_and_build ${DIRNAME}

# Get BASEDIR here
BASEDIR=$(ls -1td PS* | grep -v ".tar" | grep PS[0-9])
echo ${DIRNAME}
echo ${BASEDIR}

# Run startup.sh here
# echo "Running startup.sh from percona-qa"
# run_startup ${DIRNAME} ${BASEDIR}
#
# # Start server here
# echo "Starting Server!"
# start_server ${DIRNAME} ${BASEDIR}
#
# # Create sample database here
# DB="create database generated_columns_test"
# execute_sql ${DIRNAME} ${BASEDIR} ${DB}
#
# # Create sample table here
# TABLE="CREATE TABLE generated_columns_test.sbtest1 (
#   id int(11) NOT NULL AUTO_INCREMENT,
#   k int(11) NOT NULL DEFAULT '0',
#   c char(120) NOT NULL DEFAULT '',
#   pad char(60) NOT NULL DEFAULT '',
#   PRIMARY KEY (`id`)
# ) ENGINE=InnoDB"
# execute_sql ${DIRNAME} ${BASEDIR} ${TABLE}
#
# # Altering table engine to MyRocks here
# ALTER="alter table generated_columns_test.sbtest1 engine=rocksdb"
# execute_sql ${DIRNAME} ${BASEDIR} ${ALTER}
