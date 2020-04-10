#!/bin/bash
# Created by Roel Van de Paar, MariaDB

MYEXTRA_OPT="$*"
TESTCASES_DIR=/test/TESTCASES
RUN_BASEDIR=${PWD}

if [ -z "${MYEXTRA_OPT}" ]; then
  echo "It is highly unlikely that one would not want to pass at least:   --log-bin --sql_mode=   as options to this script (as reguarly a solid subset of the testcases will require them), so this script will wait 5 seconds now to CTRL+C if necessary..."
  sleep 5
fi

if [ ! -r bin/mysqld ]; then
  echo "Assert: bin/mysqld not available, please run this from any basedir, preferably the most recent build/the latest version used for the intial testrun, as the backtrace and version/revision used in the bug reports will be based on this base directory"
  exit 1
fi

if [ "$(echo "${PWD}" | grep -o 'opt$')" == "opt" ]; then
  echo "Likely mistake; this script is being executed from an optimized build directory, however normally a solid subset of the testcases will require a debug build, so this script will wait 5 seconds now to CTRL+C if necessary..."
  sleep 5
fi

if [ ! -d "${TESTCASES_DIR}" ]; then
  echo "Assert: '${TESTCASES_DIR}' (set in script) is not a valid directory, or cannot be read by this script."
  exit 1
fi

SCRIPT_PWD=$(cd `dirname $0` && pwd)
RANDOM=`date +%s%N | cut -b14-19`  # Random entropy init
RANDFL=$(echo $RANDOM$RANDOM$RANDOM$RANDOM | sed 's|.\(..........\).*|\1|')  # Random 10 digits filenr

LIST="/tmp/list_of_testcases.${RANDFL}"
ls ${TESTCASES_DIR}/*.sql 2>/dev/null > ${LIST}
NR_OF_TESTCASES=$(wc -l ${LIST} | sed 's| .*||')

if [ ${NR_OF_TESTCASES} -eq 0 ]; then
  echo "Assert: no SQL testcases were found at '${TESTCASES_DIR}/*.sql'"
  exit 1
fi

for i in $(seq 1 ${NR_OF_TESTCASES}); do
  TESTCASE=$(head -n${i} ${LIST} | tail -n1)
  echo "Now testing testcase ${i}/${NR_OF_TESTCASES}: ${TESTCASE}..."
  sleep 1
  cd ${RUN_BASEDIR}  # Defensive coding only
  cp ${TESTCASE} ./in.sql
  ${SCRIPT_PWD}/bug_report.sh ${MYEXTRA_OPT} > ${TESTCASE}.result
  rm -f ${TESTCASE}.result.NOCORE
  if grep -q "TOTAL CORES SEEN ACCROSS ALL VERSIONS: 0" ${TESTCASE}.result; then
    touch ${TESTCASE}.result.NOCORE
  fi
done

rm -f /tmp/list_of_testcases.${RANDFL}
