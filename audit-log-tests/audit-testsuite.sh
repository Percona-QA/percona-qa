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
  ./start --secure-file-priv=
}

function execute_sql() {
  # General function to pass sql statement to mysql client
    conn_string="$(cat $1/cl_noprompt)"
    ${conn_string} -e "$2"
}

# Functions for calling BATS tests

function run_plugin_install_check() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/plugin_install_check.bats
  else
    bats $DIRNAME/plugin_install_check.bats
  fi
}


#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

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

# Enable AUDIT plugin
INST_PLUGIN="INSTALL PLUGIN audit_log SONAME 'audit_log.so'"
execute_sql ${BASEDIR} "${INST_PLUGIN}"

# Verify the installation
run_plugin_install_check
