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
echo ${WORKDIR}
echo ${SCRIPT_PWD}

function download_tarballs() {
  # For now simply wget PS for CentOS 7
  wget https://www.percona.com/downloads/Percona-Server-5.7/Percona-Server-5.7.16-10/binary/tarball/Percona-Server-5.7.16-10-Linux.x86_64.ssl101.tar.gz
}

function pmm_framework_setup() {
  ${SCRIPT_PWD}/pmm-framework.sh --setup
}

function pmm_framwork_add_clients() {
  ${SCRIPT_PWD}/pmm-framework.sh --addclient=$1,$2
}
#
# @test "Downloading tarball" {
#   #statement
#   download_tarballs
#   [ "$status" -eq 0 ]
# }

@test "Adding clients" {
  pmm_framwork_add_clients ps 2
  [ "$status" -eq 0 ]
}
