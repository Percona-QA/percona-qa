#!/bin/bash 

SCRIPT_PWD=$(cd `dirname $0` && pwd)

mkdir -p known mysql_bugs

# Move MySQL bugs to a seperate directory
grep -A2 "Bug confirmed present in" *.report | grep MySQL | sed 's|\..*||' | sort -u | xargs -I{} mv "{}.sql" "{}.sql.report" "{}.sql.report.NOCORE" mysql_bugs 2>/dev/null

# Move bugs which were already found to be dups by mass_bug_report.sh
grep -o "FOUND: This is an already known bug" *.report | sed 's|\..*||' | sort -u | xargs -I{} mv "{}.sql" "{}.sql.report" "{}.sql.report.NOCORE" known 2>/dev/null

# Move bugs which have since been logged and/or are dups
grep -A1 "Add bug to known.strings" *.sql.report | grep -v "\-\-" | grep -vE "Add bug to known.strings|Check for duplicates before logging bug" > /tmp/tmpdups.list 2>/dev/null
COUNT=$(wc -l /tmp/tmpdups.list 2>/dev/null | sed 's| .*||')

if [ ${COUNT} -gt 0 ]; then
  LINE=0
  while true; do 
    LINE=$[ ${LINE} + 1 ]
    if [ ${LINE} -gt ${COUNT} ]; then break; fi
    SCAN="$(head -n${LINE} /tmp/tmpdups.list | tail -n1)"
    FILE="$(echo "${SCAN}" | sed 's|sql\.report-.*|sql.report|')"
    TEXT="$(echo "${SCAN}" | sed 's|.*sql\.report-||')"
    set +H  # Disables history substitution and avoids  -bash: !: event not found  like errors
    FINDBUG=$(grep -Fi --binary-files=text "${TEXT}" ${SCRIPT_PWD}/known_bugs.strings)
    if [ ! -z "${FINDBUG}" ]; then
      NR="$(echo "${FILE}" | sed 's|\.sql\.report||')"
      if [ -r ${NR}.sql.report.NOCORE ]; then
        mv "${NR}.sql" "${NR}.sql.report" "${NR}.sql.report.NOCORE" known
      else
        mv "${NR}.sql" "${NR}.sql.report" known
      fi
    fi
  done
fi
