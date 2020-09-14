#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Note that running this script does not execute pquery-clean-known.sh - run that script seperately as well, before or after this one

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

echo "Extra cleaning up of known issues++ (expert mode)..."

# Delete all likely out of disk space trials
${SCRIPT_PWD}/pquery-results.sh | grep -A1 "Likely out of disk space trials" | \
 tail -n1 | tr ' ' '\n' | grep -v "^[ \t]*$" | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}

# Delete all likely 'Server has gone away' 200x due to 'RELEASE' sql trials
${SCRIPT_PWD}/pquery-results.sh | grep -A1 "Likely 'Server has gone away' 200x due to 'RELEASE' sql" | \
 tail -n1 | tr ' ' '\n' | grep -v "^[ \t]*$" | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}

# Delete all Handlerton. error == 0 trials  # Temp re-enabled in MariaDB to test (12/9/20)
# ${SCRIPT_PWD}/pquery-results.sh | grep "Handlerton. error == 0" | grep -o "reducers.*[^)]" | \
#   sed 's|reducers ||;s|,|\n|g' | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}

# Delete all 'Assert: no core file found in' trials (benefit of new_text_string.sh)
#${SCRIPT_PWD}/pquery-results.sh | grep "Assert. no core file found in" | grep -o "reducers.*[^)]" | \
# sed 's|reducers ||;s|,|\n|g' | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}
# 9/9/2020 temp disabled to check why so many 'Assert: no core file found in */*core*' trials

# Delete all 'TRIALS TO CHECK MANUALLY' trials which do not have an associated core file in their data directories
rm -f ~/results_list++.tmp
${SCRIPT_PWD}/pquery-results.sh | grep "TRIALS.*MANUALLY" | grep -o "reducers.*[^)]" | sed 's|reducers ||;s|,|\n|g' > ~/results_list++.tmp
COUNT=$(wc -l ~/results_list++.tmp 2>/dev/null | sed 's| .*||')
for RESULT in $(seq 1 ${COUNT}); do
  if [ $(ls ${RESULT}/data/*core* 2>/dev/null | wc -l) -lt 1 ]; then
    ${SCRIPT_PWD}/pquery-del-trial.sh ${RESULT}
  fi
done
rm -f ~/results_list++.tmp

echo "Done!"
