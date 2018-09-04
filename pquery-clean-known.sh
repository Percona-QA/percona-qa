#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script deletes all known found bugs from a pquery work directory. Execute from within the pquery workdir.

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# Check if this an automated (pquery-reach.sh) run
REACH=0  # Normal output
if [ "$1" == "reach" ]; then
  REACH=1  # Minimal output, and no 2x enter required
fi

# Check if this is a pxc run
PXC=0
if [ "$(grep 'PXC Mode:' ./pquery-run.log 2> /dev/null | sed 's|^.*PXC Mode[: \t]*||' )" == "TRUE" ]; then
  PXC=1
fi

# Check if this is a group replication run
GRP_RPL=0
if [ "$(grep 'Group Replication Mode:' ./pquery-run.log 2> /dev/null | sed 's|^.*Group Replication Mode[: \t]*||')" == "TRUE" ]; then
  GRP_RPL=1
fi

# Current location checks
if [ `ls ./*/*.sql 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Assert: no pquery trials (with logging - i.e. ./*/*.sql) were found in this directory"
  exit 1
fi

if [[ ${PXC} -eq 1 || ${GRP_RPL} -eq 1 ]]; then
  cat ${SCRIPT_PWD}/known_bugs.strings > /tmp/pquery_known_bugs
  cat ${SCRIPT_PWD}/known_bugs_pxc.strings >> /tmp/pquery_known_bugs
  STRINGS_FILE=/tmp/pquery_known_bugs
else
  STRINGS_FILE=${SCRIPT_PWD}/known_bugs.strings
fi

while read line; do
  STRING="`echo "$line" | sed 's|[ \t]*##.*$||'`"
  if [ "`echo "$STRING" | sed 's|^[ \t]*$||' | grep -v '^[ \t]*#'`" != "" ]; then
    if [ `ls reducer[0-9]* 2>/dev/null | wc -l` -gt 0 ]; then
      # echo $STRING  # For debugging
      if [[ ${PXC} -eq 1 || ${GRP_RPL} -eq 1 ]]; then
	# grep -li "${STRING}" reducer[0-9]*  # For debugging (use script utility, then search for the reducer<nr>.sh in the typescript)
        grep -li "${STRING}" reducer[0-9]* | awk -F'.'  '{print substr($1,8)}' | xargs -I_ $SCRIPT_PWD/pquery-del-trial.sh _
      else
	# grep -li "${STRING}" reducer[0-9]*  # For debugging (use script utility, then search for the reducer<nr>.sh in the typescript)
        grep -li "${STRING}" reducer[0-9]* | sed 's/[^0-9]//g' | xargs -I_ $SCRIPT_PWD/pquery-del-trial.sh _
      fi
    fi
  fi
  #sync; sleep 0.02  # Making sure that next line in file does not trigger same deletions
done < ${STRINGS_FILE}

# Other cleanups
grep "CT NAME_CONST('a', -(1 [ANDOR]\+ 2)) [ANDOR]\+ 1" */log/master.err 2>/dev/null | sed 's|/.*||' | xargs -I{} ~/percona-qa/pquery-del-trial.sh {}  #http://bugs.mysql.com/bug.php?id=81407

if [ ${REACH} -eq 0 ]; then  # Avoid normal output if this is an automated run (REACH=1)
  if [ -d ./bundles ]; then
    echo "Done! Any trials in ./bundles were not touched. Any Valgrind trials were not touched."
  else
    echo "Done!"
  fi
fi
