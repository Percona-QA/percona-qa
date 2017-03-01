#!/usr/bin/env bats

#This testsuite should act as overall wrapper.
#It will call pmm-framework.sh
# - to setup PMM,
# - to add clients
# - to wipe all configurations
# It will call specific tests for eg,
# - generic-tests.bats
# - linux-metrics.bats
# - ps-specific-tests.bats


WORKDIR="${PWD}"
SCRIPT_PWD="$BATS_TEST_DIRNAME"
BLOCK=$1

function download_tarballs() {
  # For now simply wget PS for CentOS 7
  wget https://www.percona.com/downloads/Percona-Server-5.7/Percona-Server-5.7.16-10/binary/tarball/Percona-Server-5.7.16-10-Linux.x86_64.ssl101.tar.gz
}

# pmm-framework.sh functions

function pmm_framework_setup() {
  run ${SCRIPT_PWD}/pmm-framework.sh --setup
}

function pmm_framework_add_clients() {
  run ${SCRIPT_PWD}/pmm-framework.sh --addclient=$1,$2
}

function pmm_wipe_all() {
  run ${SCRIPT_PWD}/pmm-framework.sh --wipe
}

function pmm_wipe_clients() {
  run ${SCRIPT_PWD}/pmm-framework.sh --wipe-clients
}

function  pmm_wipe_server() {
  run ${SCRIPT_PWD}/pmm-framework.sh --wipe-server
}

# functions for bats calling

function run_linux_metrics_tests() {
  run bats ${SCRIPT_PWD}/linux-metrics.bats
}

function run_generic_tests() {
  run bats ${SCRIPT_PWD}/generic-tests.bats
}

function run_ps_specific_tests() {
  run bats ${SCRIPT_PWD}/ps-specific-tests.bats
}

@test "Wipe clients" {
  pmm_wipe_clients
  echo $output
  [ "$status" -eq 0 ]
}

@test "Adding clients" {
  pmm_framework_add_clients $instance_t $instance_c
  echo $output
  [ "$status" -eq 0 ]
}

@test "Running linux metrics tests" {
  run_linux_metrics_tests
  echo $output
  [ "$status" -eq 0 ]
}

@test "Running generic tests" {
  run_generic_tests
  #echo $output
  [ "$status" -eq 0 ]
  #echo $output
}

@test "Running PS specific tests" {
  run_ps_specific_tests
  echo ${output}
  [ "$status" -eq 0 ]
}

@test "Wipe clients" {
  pmm_wipe_clients
  echo $output
  [ "$status" -eq 0 ]
}



#
# @test "Downloading tarball" {
#   #statement
#   download_tarballs
#   [ "$status" -eq 0 ]
# }

# @test "Adding clients" {
#   pmm_framwork_add_clients ps 2
#   echo $output
#   [ "$status" -eq 0 ]
# }
