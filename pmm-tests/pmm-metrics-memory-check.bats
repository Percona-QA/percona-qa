# This test is for checking memory consumption from -e METRICS_MEMORY option
# I will give 750MB - give it as KB and it will multiply the value by 1024 to convert it to bytes
# Calculated as:

# 1. Get the value -e METRICS_MEMORY=768000

# Check the memory 768000*1024 is equal to the HEAP:
# pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g'

test "run pmm memory check for -e METRICS_MEMORY" {
  EXPECTED_MEMORY=786432000
  HEAP=$(pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g')
  echo $HEAP
  echo $EXPECTED_MEMORY
  echo "$output"
  [[ $HEAP == $EXPECTED_MEMORY ]]
}
