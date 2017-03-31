#!/usr/bin/env bats

WORKDIR="${PWD}"
DIRNAME="$BATS_TEST_DIRNAME"
DIRNAME=$(dirname "$0")
# pmm-framework.sh functions

function pmm_framework_setup() {
  ${DIRNAME}/pmm-framework.sh --setup
}

function pmm_framework_add_clients() {
  ${DIRNAME}/pmm-framework.sh --addclient=$1,$2
}

function pmm_wipe_all() {
  ${DIRNAME}/pmm-framework.sh --wipe
}

function pmm_wipe_clients() {
  ${DIRNAME}/pmm-framework.sh --wipe-clients
}

function  pmm_wipe_server() {
  ${DIRNAME}/pmm-framework.sh --wipe-server
}

# functions for bats calling

function run_linux_metrics_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap $DIRNAME/linux-metrics.bats
  else
    bats $DIRNAME/linux-metrics.bats
  fi
}

function run_generic_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/generic-tests.bats
  else
    bats ${DIRNAME}/generic-tests.bats
  fi
}

function run_ps_specific_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/ps-specific-tests.bats
  else
    bats ${DIRNAME}/ps-specific-tests.bats
  fi
}

function run_pxc_specific_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/pxc-specific-tests.bats
  else
    bats ${DIRNAME}/pxc-specific-tests.bats
  fi
}

function run_mongodb_specific_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/mongodb-tests.bats
  else
    bats ${DIRNAME}/mongodb-tests.bats
  fi
}

function run_proxysql_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/proxysql-tests.bats
  else
    bats ${DIRNAME}/proxysql-tests.bats
  fi
}

# Additional functions
function run_create_table() {
  bash ${DIRNAME}/create_table.sh $1 $2
}


# Running tests
echo "Wipe clients"
pmm_wipe_clients

echo "Adding clients"
pmm_framework_add_clients $instance_t $instance_c

if [[ $instance_t != "mo" ]] ; then
  echo "Running linux metrics tests"
  run_linux_metrics_tests
fi

echo "Running generic tests"
run_generic_tests

if [[ $stress == "1" ]] ; then
  echo "WARN: Running stress tests"
  run_create_table $instance_t $table_c
fi


if [[ $instance_t == "mo" ]] ; then
  echo "Running MongoDB specific tests"
  run_mongodb_specific_tests
fi


if [[ $instance_t == "ps" ]]; then
  echo "Running PS specific tests"
  run_ps_specific_tests
fi


if [[ $instance_t == "pxc" ]]; then
  echo "Running PXC specific tests"
  run_pxc_specific_tests
fi


# ProxySQL
# @test "Running ProxySQL tests" {
#   if [[ $instance_t != "pxc" ]] ; then
#   	skip "Skipping ProxySQL specific tests!"
#   fi
#   run_proxysql_tests
#   echo ${output}
#   [ "$status" -eq 0 ]
# }

# ProxySQL

echo "Wipe clients"
pmm_wipe_clients
