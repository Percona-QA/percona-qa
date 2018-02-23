# This test is for testing PMM memory consuption passed with --memory option
# Calculated as: 40% - 256MB from given value

# TOTAL_MEMORY=the value from --memory option -> hardcoded as 2147483648

# EXPECTED_MEMORY=$(( ${TOTAL_MEMORY} / 100 * 40 - 256*1024*1024 ))

# Check if HEAP is equal to EXPECTED_MEMORY
# pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g'

@test "run pmm memory consumption check from --memory=2147483648" {
  TOTAL_MEMORY=2147483648
  EXPECTED_MEMORY=$(( ${TOTAL_MEMORY} / 100 * 40 - 256*1024*1024 ))
  HEAP=$(pgrep prometheus | xargs ps -o cmd= | sed -re 's/.*--storage.local.target-heap-size=([0-9]+) .*/\1/g')
  echo $TOTAL_MEMORY
  echo $EXPECTED_MEMORY
  echo $HEAP
  echo "$output"
  [[ $HEAP == $EXPECTED_MEMORY ]]
}
