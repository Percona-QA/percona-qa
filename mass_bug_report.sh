#!/bin/bash
# Created by Roel Van de Paar, MariaDB

MYEXTRA_OPT="$*"  # Note that this is in addition to any '# mysqld options required for replay: --option1 --option2' etc. options listed inside the .sql testcases (as produced by reducer.sh), which are automatically included in the MYEXTRA options.
TESTCASES_DIR=/test/TESTCASES
RUN_BASEDIR=${PWD}

if [ ! -r bin/mysqld ]; then
  echo "Assert: bin/mysqld not available, please run this from any basedir, preferably the most recent build/the latest version used for the intial testrun, as the backtrace and version/revision used in the bug reports will be based on this base directory"
  exit 1
fi

if [ ! -r ./all_no_cl ]; then
  echo "Assert: ./all_no_cl not available, please run this from a basedir which was prepared with ${SCRIPT_PWD}/startup.sh"
  exit 1
fi

if [ ! -r ../kill_all ]; then
  echo "Assert: ../kill_all not available, wrong infrastructure setup, please copy contents of ${SCRIPT_PWD}/mariadb-build-qa to .."
  exit 1
fi

if [ ! -r ../check ]; then
  echo "Assert: ../check not available, wrong infrastructure setup, please copy contents of ${SCRIPT_PWD}/mariadb-build-qa to .."
  exit 1
fi


if [ "$(echo "${PWD}" | grep -o 'opt$')" == "opt" ]; then
  echo "Possible mistake; this script is being executed from an optimized build directory, however normally a solid subset of the testcases will require a debug build, and this script will use the current BASEDIR as the authorative source for prodicing the gdb backtrace displayed in the bug report. IOW, if there are debug-only testcases in ${TESTCASES_DIR} then there will likely not be any proper statck traces produced for those. To avoid this issue, simply CTRL+C now and run this script again from a debug build. This script will wait 5 seconds now to CTRL+C if necessary..."
  sleep 5
fi

if [ ! -d "${TESTCASES_DIR}" ]; then
  echo "Assert: '${TESTCASES_DIR}' (set in script) is not a valid directory, or cannot be read by this script."
  exit 1
fi

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
RANDOM=`date +%s%N | cut -b14-19`  # Random entropy init
RANDFL=$(echo $RANDOM$RANDOM$RANDOM$RANDOM | sed 's|.\(..........\).*|\1|')  # Random 10 digits filenr

LIST="/tmp/list_of_testcases.${RANDFL}"
ls ${TESTCASES_DIR}/*.sql 2>/dev/null > ${LIST}
NR_OF_TESTCASES=$(wc -l ${LIST} | sed 's| .*||')

if [ ${NR_OF_TESTCASES} -eq 0 ]; then
  echo "Assert: no SQL testcases were found at '${TESTCASES_DIR}/*.sql'"
  exit 1
fi

# Create clean environment
cd ..
for i in $(seq 1 3); do
  ./kill_all  # Can not be executed as ../kill_all as it requires ./gendirs.sh
  sync
  sleep 0.2
done
cd ${RUN_BASEDIR}

for i in $(seq 1 ${NR_OF_TESTCASES}); do
  TESTCASE=$(head -n${i} ${LIST} | tail -n1)
  echo "------------------------------------------------------------------------------"
  echo "Now testing testcase ${i}/${NR_OF_TESTCASES}: ${TESTCASE}..."
  echo "------------------------------------------------------------------------------"
  echo "Now testing testcase ${i}/${NR_OF_TESTCASES}: ${TESTCASE}..." > current.testcase
  sleep 1
  rm -f ${TESTCASE}.report ${TESTCASE}.report.NOCORE
  cd ${RUN_BASEDIR}/..
  ./check  # Ensure that basedir dirs are still in top shape
  if [ ${?} -ne 0 ]; then
    echo "Assert: ./check failed!"
    exit 1
  fi
  cd ${RUN_BASEDIR}
  cp ${TESTCASE} ./in.sql
  MAX_DURATION=900  # 15 Minutes, normal runtime (if not OOM) is <= 1 min with ~20 instances
  timeout -k${MAX_DURATION} -s9 ${MAX_DURATION}s ${SCRIPT_PWD}/bug_report.sh ${MYEXTRA_OPT} > ${TESTCASE}.report
  cd ${RUN_BASEDIR}/..
  ./kill_all  # If bug_report was halted, this will stop all running instaces
  sync
  cd ${RUN_BASEDIR}
  if grep -q "TOTAL CORES SEEN ACCROSS ALL VERSIONS: 0" ${TESTCASE}.report; then
    touch ${TESTCASE}.report.NOCORE
  fi
done

rm -f /tmp/list_of_testcases.${RANDFL} current.testcase

echo "--------------------------------------------------------------------------------------------"
echo "Done! Please check ${TESTCASES_DIR}/*report* files!"
echo "A '{testcase}.sql.report.NOCORE' flag file was added for issues which did not reproduce on any basedir"
