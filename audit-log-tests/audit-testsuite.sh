#!/bin/bash

# Created by Shahriyar Rzayev from Percona

WORKDIR="${PWD}"
DIRNAME=$(dirname "$0")

# Preparing test env

function clone_and_build() {
  git clone --recursive --depth=1 https://github.com/percona/percona-server.git -b 5.7 PS-5.7-trunk
  cd $1/PS-5.7-trunk
  # from percona-qa repo
  ~/percona-qa/build_5.x_debug_for_audit_plugin.sh
}

function run_startup() {
  cd $1
  # from percona-qa repo
  ~/percona-qa/startup.sh
}

function start_server() {
  cd $1
  ./start --plugin-load-add=audit_log=audit_log.so --audit_log_format=json --secure-file-priv=
  cd ..
}

function execute_sql() {
  # General function to pass sql statement to mysql client
    conn_string="$(cat $1/cl_noprompt)"
    ${conn_string} -e "$2"
}

function flush_audit_log() {
  # Function for flushing log prior executing each statement.
  # $1 path basedir
  rm -f $1/data/audit.log
  SQL="set global audit_log_flush=ON"
  execute_sql $1 "$SQL"
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

function run_audit_log_include_commands() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/audit_log_include_commands.bats
  else
    bats $DIRNAME/audit_log_include_commands.bats
  fi
}

function run_audit_log_include_databases() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/audit_log_include_databases.bats
  else
    bats $DIRNAME/audit_log_include_databases.bats
  fi
}

function run_audit_log_format() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/audit_log_format.bats
  else
    bats $DIRNAME/audit_log_format.bats
  fi
}

function run_audit_include_accounts() {
  # Calling bats file
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/audit_include_accounts.bats
  else
    bats $DIRNAME/audit_include_accounts.bats
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
echo "Installing the plugin"
# INST_PLUGIN="INSTALL PLUGIN audit_log SONAME 'audit_log.so'"
# execute_sql ${BASEDIR} "${INST_PLUGIN}"

# Verify the installation
run_plugin_install_check

# Flush audit.log file First
flush_audit_log ${BASEDIR}
# Call audit_log_include_commands.bats tests here
run_audit_log_include_commands
# Flush audit.log file First
flush_audit_log ${BASEDIR}
# Call audit_log_include_databases.bats tests here
run_audit_log_include_databases
# Call audit_log_format.bats file here
run_audit_log_format
# Flush audit.log file First
flush_audit_log ${BASEDIR}
