#!/usr/bin/env bats

WORKDIR="${PWD}"
DIRNAME="$BATS_TEST_DIRNAME"
DIRNAME=$(dirname "$0")
# pmm-framework.sh functions

function pmm_framework_setup() {
  ${DIRNAME}/pmm-framework.sh --setup
}

function pmm_framework_add_clients() {
  ${DIRNAME}/pmm-framework.sh --addclient=$1,$2 --${1}-version=$3 --download
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

# functions for some env setup

function setup_local_consul_exporter() {
  echo "Setting up consul_exporter"
  FILE_NAME="consul_exporter-0.3.0.linux-amd64.tar.gz"

  if [ -f ${FILE_NAME}  ]; then
    echo "File exists"
  else
    wget https://github.com/prometheus/consul_exporter/releases/download/v0.3.0/consul_exporter-0.3.0.linux-amd64.tar.gz
    tar -zxpf consul_exporter-0.3.0.linux-amd64.tar.gz
  fi

  IP_ADDR=$(ip route get 1 | awk '{print $NF;exit}')
  echo "Running consul_exporter"
  echo "IMPORTANT: pmm-server docker should be run with additional -p 8500:8500"
  ./consul_exporter-0.3.0.linux-amd64/consul_exporter -consul.server http://${IP_ADDR}:8500 > /dev/null 2>&1 &
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

function run_postgresql_specific_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/pgsql-specific-tests.bats
  else
    bats ${DIRNAME}/pgsql-specific-tests.bats
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

function run_external_exporters_tests() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/external_exporters_tests.bats
  else
    bats ${DIRNAME}/external_exporters_tests.bats
  fi
}

function run_pmm_default_memory_check() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/pmm-default-memory-check.bats
  else
    bats ${DIRNAME}/pmm-default-memory-check.bats
  fi
}

function run_pmm_memory_check() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/pmm-memory-check.bats
  else
    bats ${DIRNAME}/pmm-memory-check.bats
  fi
}

function run_pmm_metrics_memory_check() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/pmm-metrics-memory-check.bats
  else
    bats ${DIRNAME}/pmm-metrics-memory-check.bats
  fi
}

function run_pmm_slow_log_rotation_check() {
  if [[ $tap == 1 ]] ; then
    bats --tap ${DIRNAME}/pmm-slow-log-rotation-tests.bats
  else
    bats ${DIRNAME}/pmm-slow-log-rotation-tests.bats
  fi
}
# Additional functions
function run_create_table() {
  bash ${DIRNAME}/create_table.sh $1 $2
}

function run_populate_table() {
  bash ${DIRNAME}/populate_table.sh $1 $2 $3
}

# Setting up the PMM using pmm_framework_setup() here
# if [[ $setup == "1" ]]; then
#   # Check if both options are passed.
#   if [[ $pmm_server_memory == "1" && $pmm_docker_memory == "1" ]]; then
#     echo "Please use one of the options to limit the memory!"
#     exit 1
#   fi
#   # Pass values to setup script
#   if [[ $pmm_server_memory == "1" ]]; then
#     METRICS_MEMORY="--pmm-server-memory=768000"
#     pmm_framework_setup $METRICS_MEMORY
#   elif [[ $pmm_docker_memory == "1" ]]; then
#     MEMORY="--pmm-docker-memory=2147483648"
#     pmm_framework_setup $MEMORY
#   else
#     pmm_framework_setup ""
#   fi
# fi

# Running tests
echo "Wipe clients"
pmm_wipe_clients

echo "Adding clients"
pmm_framework_add_clients $instance_t $instance_c $version

if [[ $instance_t != "mo" ]] ; then
  echo "Running linux metrics tests"
  run_linux_metrics_tests
fi

echo "Running generic tests"
run_generic_tests

echo "Running default memory consumption check"
if [[ -z $pmm_server_memory &&  -z $pmm_docker_memory ]]; then
  run_pmm_default_memory_check
elif [[ $pmm_server_memory != "1" &&  $pmm_docker_memory != "1" ]]; then
  run_pmm_default_memory_check
else
  echo "OK - Skipped"
fi

echo "Running memory consumption check for --memory option"
if [[ $pmm_docker_memory == "1" ]]; then
  run_pmm_memory_check
else
  echo "OK - Skipped"
fi

echo "Running memory consumption check for -e METRICS_MEMORY option"
if [[ $pmm_server_memory == "1" ]]; then
  run_pmm_metrics_memory_check
else
  echo "OK - Skipped"
fi

echo "Running Slow Log rotation tests [PMM-2432]"
run_pmm_slow_log_rotation_check

echo "Running external exporters tests"
setup_local_consul_exporter
run_external_exporters_tests

if [[ $stress == "1" && $table_c != "0" && -z $table_size ]] ; then
  echo "WARN: Running stress tests; creating empty tables"
  run_create_table $instance_t $table_c
elif [[ $stress == "1" && $table_c != "0" && $table_size != "0" ]] ; then
  echo "WARN: Running stress tests; creating tables and inserting using sysbench"
  run_populate_table $instance_t $table_c $table_size
else
  echo "Skipping stress test!"
fi


if [[ $instance_t == "mo" ]] ; then
  echo "Running MongoDB specific tests"
  run_mongodb_specific_tests
fi


if [[ $instance_t == "ps" ]]; then
  echo "Running PS specific tests"
  run_ps_specific_tests
fi

if [[ $instance_t == "pgsql" ]]; then
  echo "Running Postgre SQL specific tests"
  run_postgresql_specific_tests
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
