#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script eliminates duplicate trials where at least x trials are present for a given issue, and x trials are kept for each such issue where duplicates are eliminated. Execute from within the pquery workdir. x is defined by the number of [0-9]\+, entries

# User variables
TRIALS_TO_KEEP=3  # Set high (for example: 10) when there are few bugs seen in each new round. Set low (for example: 2) when handling many new bugs/when many bugs are seen in the runs

# Internal variables
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

# Checks
if [ ! -r pquery-run.log -o ! -d mysqld ]; then 
  echo 'This directory is not a pquery run directory it seems! Terminating'
  exit 1
fi
if [ -z "${TRIALS_TO_KEEP}" ]; then 
  echo 'Assert: TRIALS_TO_KEEP is empty. Terminating'
  exit 1
elif [ "$(echo "${TRIALS_TO_KEEP}" | grep -o '[0-9]\+')" != "${TRIALS_TO_KEEP}" ]; then
  echo "Assert: TRIALS_TO_KEEP (${TRIALS_TO_KEEP}) is not numerical. Terminating"
  exit 1
elif [ "${TRIALS_TO_KEEP}" -lt 2 ]; then
  echo "Assert: TRIALS_TO_KEEP (${TRIALS_TO_KEEP}) is less then 2. Minimum: TRIALS_TO_KEEP=2. Please fix setup. Terminating"
  exit 1
fi

generate_string(){
  STRING='[0-9]\+'
  for cnt in $(seq 2 ${TRIALS_TO_KEEP}); do
    STRING="${STRING},[0-9]\+"
  done
}

# Keep x trials
SED_STRING='[0-9]\+,'
for cnt in $(seq 2 ${TRIALS_TO_KEEP}); do
  SED_STRING="${SED_STRING}"'[0-9]\+,'  # Prepare a replace string which equals TRIALS_TO_KEEP trials
done
SEARCH_STRING="${SED_STRING}"'.*'  # Find reducers with at least TRIALS_TO_KEEP+1 trials. The '+1', whilst likely not strictly necessary, is an extra safety measure and is guaranteed by the ',' added at the end of SED_STRING as created above. After SEARCH_STRING is created, we remove the comma as the SED_STRING should only match the exact number of trials as set by TRIALS_TO_KEEP
SED_STRING="$(echo "${SED_STRING}" | sed 's|,$||')"  # Remove the last comma for the SED_STRING only

${SCRIPT_PWD}/pquery-results.sh | grep --binary-files=text -v 'TRIALS TO CHECK MANUALLY' | sed 's|_val||g' | grep --binary-files=text -oE "Seen[ \t]+[0-9][0-9]+ times.*,.*|Seen[ \t]+[2-9] times.*,.*" | grep --binary-files=text -o "reducers ${SEARCH_STRING}" | sed "s|reducers ${SED_STRING}||" | sed 's|)||;s|,|\n|g' | grep --binary-files=text -v '^[ \t]*$' | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}
