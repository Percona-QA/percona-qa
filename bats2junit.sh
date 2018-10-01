#!/usr/bin/env bash
# This script transforms bats test results into junit format which jenkins understands
# run bats test with "bats --tap <test_file> | tee test-output.txt"
# then run this script like "bats2junit.sh test-output.txt <suite-name>"
# Created by Tomislav Plavcic, Percona LLC

INPUT_FILE=""
SUITE_NAME=""
FAILURE_MODE=0

if [ "$#" -ne 2 ]; then
  echo "Usage:"
  echo "  bats2junit.sh <input-filename> <suite-name>"
fi

INPUT_FILE="$1"
SUITE_NAME="$2"

echo "<testsuite name=\"${SUITE_NAME}\">"

while read p; do
  if [[ $p =~ ^(ok [0-9]* # skip \()(.*\) )(.*)$ ]]; then
    if [[ ${FAILURE_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAILURE_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[3]}\">"
    echo -e "  <skipped/>\n  <system-out>Skip reason:\n<![CDATA["
    echo "${BASH_REMATCH[2]::-2}"
    echo -e "]]>\n  </system-out>\n</testcase>"
  elif [[ $p =~ ^(ok [0-9]* # skip )(.*)$ ]]; then
    if [[ ${FAILURE_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAILURE_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[2]}\">"
    echo "  <skipped/>"
    echo "</testcase>"
  elif [[ $p =~ ^(ok [0-9]* )(.*)$ ]]; then
    if [[ ${FAILURE_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAILURE_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[2]}\"/>"
  elif [[ $p =~ ^(not ok [0-9]* )(.*)$ ]]; then
    if [[ ${FAILURE_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; fi
    echo "<testcase name=\"${BASH_REMATCH[2]}\">"
    echo -e "  <failure>\n<![CDATA["
  elif [[ "${FAILURE_MODE}" -eq 1 ]]; then
    echo "$p"
  fi
done < ${INPUT_FILE}

  echo "</testsuite>"
