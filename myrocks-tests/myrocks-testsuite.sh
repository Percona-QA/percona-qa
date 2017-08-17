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
  cd ${1}/${2}
  ~/percona-qa/startup.sh
}

function start_server() {
  cd ${1}/${2}
  ./start
}

# Run clone and build here
clone_and_build ${DIRNAME}

# Get BASEDIR here
BASEDIR=$(ls -1td PS* | grep -v ".tar" | grep PS[0-9])

# Run startup.sh here
run_startup ${DIRNAME} ${BASEDIR}

# Start server here
start_server ${DIRNAME} ${BASEDIR}
