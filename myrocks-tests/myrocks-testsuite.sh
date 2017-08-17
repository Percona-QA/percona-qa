#!/usr/bin/env bats

# Created by Shahriyar Rzayev from Percona

WORKDIR="${PWD}"
DIRNAME="$BATS_TEST_DIRNAME"
DIRNAME=$(dirname "$0")

# Preparing test env

function clone_and_build() {
  git clone --recursive --depth=1 https://github.com/percona/percona-server.git -b 5.7 PS-5.7-trunk
  cd PS-5.7-trunk
  ~/percona-qa/build_5.x_debug.sh
}

function startup() {
  ~/percona-qa/startup.sh
}

clone_and_build

startup
