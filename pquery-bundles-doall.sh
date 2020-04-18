#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script is handy once you've worked through a pquery run/work directory (i.e. tried reducer<nr>.sh scripts to generate testcases),
# and there are a number of bugs left for which testcase creation has failed for one reason or another. In this case, simply start this
# script from within the pquery run/work dir and it will generate bundles, and a handy copy of the error log and gdb trace, to make bug
# logging a breeze. Just see the resulting .err and .gdb files for bug details, and the bundle can be uploaded as it has ALL files
# a developer could one for analysis (minus a testcase that is).

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

if [ `ls reducer* 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Assert, we did not find any reducer scripts in this directory - did you already execute pquery-prep-red.sh ?"
  exit 1
fi

if [ `ls | grep "^[0-9]\+$" | wc -l` -eq 0 ]; then
  echo "Assert, we did not find any pquery trial scripts in this directory. Execute this script from within the pqeury workdir."
  exit 1
fi

# Check for pre-existing ./bundles dir, and create one if not present
if [ ! -d ./bundles ]; then
  mkdir bundles
  if [ ! -d ./bundles ]; then
    echo "Assert: we tried to create an ./bundles directory, but it failed?"
    exit 1
  fi
else
  echo "Using existing ./bundles directory for storage."
fi

${SCRIPT_PWD}/pquery-clean-known.sh >/dev/null 2>&1
PQUERY_DIR=`${SCRIPT_PWD}/pquery-results.sh | grep "(Seen" | sed 's|.*(Seen.*reducers ||;s|,.*||;s|).*||'`

for i in ${PQUERY_DIR[*]}; do
  TRIALNR=$i
  echo "===== Processing trial #${TRIALNR}"
  ${SCRIPT_PWD}/pquery-create-bundle.sh ${TRIALNR}
  mv ${TRIALNR}_bundle.tar.gz ./bundles
  cp ${TRIALNR}_bundle/master.err ./bundles/${TRIALNR}.err
  cp ${TRIALNR}_bundle/gdb*STD.txt ./bundles/${TRIALNR}.gdb
done

echo "Done! All bundles can be found in ./bundles. Note that .err and .gdb files can be deleted after logging bug, they are just to make it easier to"
echo "log bugs nicely with stack trace and relevant error log content (assert message etc.). The bundles contain ALL files necessary for dev in themselves."
