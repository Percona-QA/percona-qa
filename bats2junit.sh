#!/usr/bin/env bash
# This script transforms bats test results into junit format which jenkins understands
# run bats test with "bats --tap <test_file> | tee test-output.txt"
# then run this script like "bats2junit.sh test-output.txt <suite-name>"
# Created by Tomislav Plavcic, Percona LLC

INPUT_FILE=""
SUITE_NAME=""
FAIL_MODE=0

if [ "$#" -ne 2 ]; then
  echo "Usage:"
  echo "  bats2junit.sh <input-filename> <suite-name>"
fi

INPUT_FILE="$1"
SUITE_NAME="$2"
CHECK_SKIP_COM="^(ok [0-9]* # skip \()(.*\) )(.*)$"
CHECK_SKIP="^(ok [0-9]* # skip )(.*)$"
CHECK_OK="^(ok [0-9]* )(.*)$"
CHECK_FAIL="^(not ok [0-9]* )(.*)$"

echo "<testsuite name=\"${SUITE_NAME}\">"

while read p; do
  if [[ $p =~ $CHECK_SKIP_COM ]]; then
    if [[ ${FAIL_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAIL_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[3]}\">"
    echo -e "  <skipped/>\n  <system-out>Skip reason:\n<![CDATA["
    echo "${BASH_REMATCH[2]%??}"
    echo -e "]]>\n  </system-out>\n</testcase>"
  elif [[ $p =~ $CHECK_SKIP ]]; then
    if [[ ${FAIL_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAIL_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[2]}\">"
    echo "  <skipped/>"
    echo "</testcase>"
  elif [[ $p =~ $CHECK_OK ]]; then
    if [[ ${FAIL_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAIL_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[2]}\"/>"
  elif [[ $p =~ $CHECK_FAIL ]]; then
    if [[ ${FAIL_MODE} -eq 1 ]]; then echo -e "]]>\n  </failure>\n</testcase>"; FAIL_MODE=0; fi
    echo "<testcase name=\"${BASH_REMATCH[2]}\">"
    echo -e "  <failure>\n<![CDATA["
    FAIL_MODE=1
  elif [[ "${FAIL_MODE}" -eq 1 ]]; then
    echo "$p"
  fi
done < ${INPUT_FILE}

  echo "</testsuite>"
