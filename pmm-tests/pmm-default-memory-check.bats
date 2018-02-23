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

@test "run pmm default memory consumption check" {
  TOTAL_MEMORY=$(( $(grep MemTotal /proc/meminfo | awk '{print$2}') * 1024 ))
  EXPECTED_MEMORY=$(( ${TOTAL_MEMORY} / 100 * 40 - 256*1024*1024 ))
  HEAP=$(pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g')
  echo $TOTAL_MEMORY
  echo $EXPECTED_MEMORY
  echo $HEAP
  echo "$output"
      [ "$status" -eq 1 ]
      [ $HEAP == $EXPECTED_MEMORY]
}
