#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)
KNOWN_BUGS_LIST=${SCRIPT_PWD}/known_bugs_tokumxse.strings
WORKDIR=${PWD}

echoit(){
  echo "[$(date +'%T')] $1"
}

echoit "Init check..."
COUNT=$(ls -l */single_test_mongo.log 2>/dev/null | wc -l)
if [ ${COUNT} -eq 0 ]; then
  echoit "Assert: no subdirectories which contain the file single_test_mongo.log found. Are you in the correct MJR results directory?"
  exit 1
else
  echoit "Found ${COUNT} individual trials, now tagging all known bugs..."
fi

if [ $(ls -l */this_trial_was_interrupted.txt 2>/dev/null | wc -l) -gt 0 ]; then
  VAR=`ls -d [0-9]*`; for DIRECTORY in ${VAR[*]}; do
    if [ -r ${DIRECTORY}/this_trial_was_interrupted.txt ]; then
      echoit "Filtering known early trial interruption (you may want to consider increasing the per-trial timeout \$TIMEOUT in MJR)"
      if [ -d ${DIRECTORY} ]; then mv ${DIRECTORY} ${DIRECTORY}_TIMEOUT; fi
    fi
  done
fi
DIRECTORY=

while read LINE; do
  if [ "$(echo "${LINE}" | sed 's|[ \t]*\(.\).*|\1|')" == "#" ]; then continue; fi  # Drop comment lines with a leading "#"
  if [ "$(echo "${LINE}" | sed 's|[ \t]*||')" == "" ]; then continue; fi            # Drop empty lines
  TEST="$(echo "${LINE}" | sed 's/|.*//')"
  INFO="$(echo "${LINE}" | sed 's/.*|//;s/ .*//')"
  # echo "TEST = ${TEST} | INFO = ${INFO}"  # Debug
  QUALIFIES=$(grep "${TEST}" */single_test_mongo.log | head -n2 | sed 's|.*>[ \t]*||;s|[ \t]*for.*||' | tr -d '\n' | tr -d ' ')
  DIRECTORY=$(grep "${TEST}" */single_test_mongo.log | head -n1 | sed 's|\([0-9]\+\).*|\1|')  # This would be empty if no qualifying directory was found
  # Note: -d Directory check cannot be globalized, due to num regex (ref above in DIRECTORY=). The per-if checks prevent further renames on re-run as they do not match
  if [ "${DIRECTORY}" != "" ]; then  # There is a qualifying issue (ref above in DIRECTORY=)
    if [ "${INFO}" == "single" ]; then
      echoit "TEMPORARY HACK: Filtering known test issue (single thread test required) for ${TEST}, individual trial directory ${DIRECTORY}, no logged case"
      if [ -d ${DIRECTORY} ]; then mv ${DIRECTORY} ${DIRECTORY}_SINGLE; fi
      QUALIFIES=  # Reset to empty for non-empty check below
    elif [ "${QUALIFIES}" == '1testssucceeded0testssucceeded' ]; then
      echoit "Filtering known issue for ${TEST}, individual trial directory ${DIRECTORY}, logged case ${INFO}"
      if [ -d ${DIRECTORY} ]; then mv ${DIRECTORY} ${DIRECTORY}_${INFO}; fi
      QUALIFIES=  # Reset to empty for non-empty check below
    elif [ "${QUALIFIES}" == '0testssucceeded' ]; then
      echoit "Filtering known issue (non-finished test) for ${TEST}, individual trial directory ${DIRECTORY}, logged case ${INFO}"
      if [ -d ${DIRECTORY} ]; then mv ${DIRECTORY} ${DIRECTORY}_${INFO}; fi
      QUALIFIES=  # Reset to empty for non-empty check below
    fi
  fi
  if [ "${QUALIFIES}" != '' ]; then
    echoit "Assert: \$QUALIFIES != '' - this should not happen. \$QUALFIES: ${QUALIFIES}. \$TEST=${TEST}. \$DIRECTORY=${DIRECTORY}"
    exit 1
  fi
done < ${KNOWN_BUGS_LIST}
