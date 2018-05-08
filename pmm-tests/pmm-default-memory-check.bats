#!/usr/bin/env bats

# Checking default memory consuption of PMM.
# This bats run is for checking -> if the 40% - 256MB of memory was taken from all available RAM on server.
# This is valid when no --memory and -e METRICS_MEMORY options are passed to docker run command.

# THE logic:
# 1. Get the total available memory from server
# TOTAL_MEMORY=$(( $(grep MemTotal /proc/meminfo | awk '{print$2}') * 1024 ))

# 2. Get the expected memory consumption
# EXPECTED_MEMORY=$(( ${TOTAL_MEMORY} / 100 * 40 - 256*1024*1024 ))

# 3. Check the heap is equal to EXPECTED_MEMORY or not
# pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g'
setup() {
  export PMM=$(sudo pmm-admin info| grep 'PMM Server'|awk '{print $4}')
  export USER=$(sudo pmm-admin show-passwords| grep 'User'|awk '{print $3}')
  export PASSWORD=$(sudo pmm-admin show-passwords| grep 'Password'|awk '{print $3}')
  export SSL=$(sudo pmm-admin info |grep 'SSL')
  export HTTP='http'
  export VERSION=$( curl --insecure -s --head $AUTH  $HTTP://${PMM}/configurator/v1/version|awk -F'"' '{ print $10 }')
  echo $VERSION
  if [ -n "$SSL" ] ;  then
    export HTTP='https'
  fi
  if [ -n "$USER" ] ; then
    export AUTH="-u '$USER:$PASSWORD'"
  else
   export AUTH=""
  fi
}

@test "run pmm default memory consumption check" {
  skip
  TOTAL_MEMORY=$(( $(grep MemTotal /proc/meminfo | awk '{print$2}') * 1024 ))
  if [[ $(echo $VERSION | grep -o "^[0-9]\.[0-9]" | tr -d '.') -lt 19 ]]; then
    EXPECTED_MEMORY=$(( ${TOTAL_MEMORY} / 100 * 40 - 256 * 1024 * 1024 ))
  else
    EXPECTED_MEMORY=$(( ${TOTAL_MEMORY} - 256 * 1024 * 1024 / 100 * 40 ))
  fi
  HEAP=$(pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g')
  echo $TOTAL_MEMORY
  echo $EXPECTED_MEMORY
  echo $HEAP
  echo "$output"
   [[ $HEAP == $EXPECTED_MEMORY ]]
}
