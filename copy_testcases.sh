#!/bin/bash

TARGET="${1}"
if [ -z "${TARGET}" ]; then
  if [ -d "/data/TESTCASES" ]; then
    echo "As it exists, and there is no risk (cp -n), assuming /data/TESTCASES is target directory"
    TARGET="/data/TESTCASES"
  else
    echo "This script expects one parameter: the path to where it should copy all testcases found in the current directory and the subdirectories below it (which it will traverse). The path does not need to currently exist, but the location does need to writable. For example, use:"
    echo "~/tc /data/TESTCASES"
    exit 1
  fi
fi
mkdir -p "${TARGET}"
if [ ! -r "${TARGET}" ]; then
  echo "Assert: we tried to create ${TARGET}, but something went amiss and the path does not exist"
  exit 1
fi
LAST=$(ls "${TARGET}" | grep ".sql$" | sort -n | tail -n1 | grep -o '[0-9]\+')
COUNT_CUR=$(ls "${TARGET}" | wc -l)
COUNT=$(find . | grep "_out$" | wc -l)
echo "Current directory (from where testcases will be copied) = ${PWD}"
echo "Target directory (to where testcases will be copied)    = ${TARGET}"
echo "Current overall nr of testcases in the target directory = ${COUNT_CUR}"
echo "Current last testcase number # in the target directory  = ${LAST}"
echo "New testcases about to be copied in to the target dir.  = ${COUNT}"
echo "First number used for new testcases to be copied in     = $[ ${LAST} + 1 ]"
find . | grep "_out$" | cat -n | while read n f; do n=$[ ${LAST} +${n} ]; cp -n "$f" "${TARGET}/$n.sql"; done
COUNT_NEW=$(ls "${TARGET}" | wc -l)
echo "Copied. New amount in the target directory              = ${COUNT_NEW}"
if [ $[ ${COUNT_CUR} + ${COUNT} ] -eq ${COUNT_NEW} ]; then
  echo "Safety check: CORRECT, ALL GOOD"
  exit 0
else
  echo "Safety check: FAILED! Number of testcases did not match rule old + new = current new. Please check!"
  exit 1
fi
