#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Note that running this script does not execute pquery-clean-known.sh - run that script seperately as well, before or after this one

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

echo "Extra cleaning up of known issues++ (expert mode)..."

# Delete all known bugs which do not correctly produce unique bug ID's due to stack smashing etc
grep 'Assertion .state_ == s_exec || state_ == s_quitting. failed.' */log/master.err 2>/dev/null | sed 's|^\([0-9]\+\)/.*|\1|' | grep -o '[0-9]\+' | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}  # MDEV-22148
grep 'Assertion .thd->transaction->stmt.is_empty() || thd->in_sub_stmt. failed.' */log/master.err 2>/dev/null | sed 's|^\([0-9]\+\)/.*|\1|' | grep -o '[0-9]\+' | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}  # MDEV-22726

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
# Check first if this is not an ASAN run. If any ASAN '=ERROR:' or UBSAN 'runtime error:' is seen at all, no trials will be deleted for the 'Assert. no core file found in' string produced by new_text_string, as there are likely error logs/trials with ASAN errors where no core file was present as ASAN terminated the mysqld instance/trial
if [ $(grep -m1 --binary-files=text "=ERROR:" */log/master.err 2> /dev/null | wc -l) -eq 0 -a $(grep -m1 --binary-files=text "runtime error:" */log/master.err 2> /dev/null | wc -l) -eq 0 ]; then
  sleep 0  # Dummy instruction to enable if to remain active irrespective of disabled next line
  # ${SCRIPT_PWD}/pquery-results.sh | grep "Assert. no core file found in" | grep -o "reducers.*[^)]" | sed 's|reducers ||;s|,|\n|g' | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}
fi
# 9/9/2020 temp disabled to check why so many 'Assert: no core file found in */*core*' trials
# 22/9/2020 temp re-enabled (temp re-disable again later) due to so many bugs in queues
# 11/11/2020 re-disabled

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
