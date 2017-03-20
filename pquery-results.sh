#!/bin/bash
# Created by Roel Van de Paar, Percona LLC
# Usage example"
#  For normal output            : $./pquery-results.sh
#  For Valgrind + normal output : $./pquery-results.sh valgrind

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# Check if this is a pxc run
if [ "$(grep 'PXC Mode:' ./pquery-run.log 2> /dev/null | sed 's|^.*PXC Mode[: \t]*||' )" == "TRUE" ]; then
  PXC=1
else
  PXC=0
fi

# Check if this is a group replication run
if [ "$(grep 'Group Replication Mode:' ./pquery-run.log 2> /dev/null | sed 's|^.*Group Replication Mode[: \t]*||')" == "TRUE" ]; then
  GRP_RPL=1
else
  GRP_RPL=0
fi

# Current location checks
if [ `ls ./*/*.sql 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Assert: no pquery trials (with logging - i.e. ./*/*.sql) were found in this directory (or they were all cleaned up already)"
  echo "Please make sure to execute this script from within the pquery working directory!"
  exit 1
elif [ `ls ./reducer* ./qcreducer* 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Assert: no reducer scripts were found in this directory. Did you forgot to execute ${SCRIPT_PWD}/pquery-prep-red.sh ?"
  exit 1
fi

# String (TEXT=string) specific trials (commonly these are MODE=3 trials)
TRIALS_EXECUTED=$(cat pquery-run.log 2>/dev/null | grep -o "==.*TRIAL.*==" | tail -n1 | sed 's|[^0-9]*||;s|[ \t=]||g')
echo "================ [Run: $(echo ${PWD} | sed 's|.*/||')] Sorted unique issue strings (${TRIALS_EXECUTED} trials executed, `ls reducer*.sh qcreducer*.sh 2>/dev/null | wc -l` remaining reducer scripts)"
ORIG_IFS=$IFS; IFS=$'\n'  # Use newline seperator instead of space seperator in the for loop
if [[ $PXC -eq 0 && $GRP_RPL -eq 0 ]]; then
  for STRING in `grep "   TEXT=" reducer* 2>/dev/null | sed 's|.*:||;s|"|.|g' | sort -u`; do
    MATCHING_TRIALS=()
    for MATCHING_TRIAL in `grep -H "${STRING}" reducer* 2>/dev/null | awk '{print $1}' | sed 's|:.*||;s|[^0-9]||g' | sort -un` ; do
      MATCHING_TRIAL=$(echo ${MATCHING_TRIAL} | sed 's|.*TEXT=.||;s|\.[ \t]*$||')
      MATCHING_TRIALS+=($MATCHING_TRIAL)
    done
    STRING=$(echo ${STRING} | sed 's|.*TEXT=.||;s|\.[ \t]*$||')
    COUNT=`grep "   TEXT=" reducer* 2>/dev/null | sed 's|reducer\([0-9]\).sh:|reducer\1.sh:  |;s|reducer\([0-9][0-9]\).sh:|reducer\1.sh: |;s|  TEXT|TEXT|' | grep "${STRING}" | wc -l`
    STRING_OUT=`echo $STRING | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}$(echo ${MATCHING_TRIALS[@]}|sed 's| |,|g'))"
  done
else
  for STRING in `grep "   TEXT=" reducer* 2>/dev/null | sed 's|.*TEXT="||;s|"$||' | sort -u`; do
    MATCHING_TRIALS=()
    for TRIAL in `grep -H "${STRING}" reducer* 2>/dev/null | awk '{print $1}' | cut -d'-' -f1 | tr -d '[:alpha:]' | sort -un` ; do
      MATCHING_TRIAL=`grep -H "   TEXT=" reducer${TRIAL}-* 2>/dev/null | sed 's|reducer\([0-9]\).sh:|reducer\1.sh:  |;s|reducer\([0-9][0-9]\).sh:|reducer\1.sh: |;s|  TEXT|TEXT|' | grep "${STRING}" | sed "s|.sh.*||;s|reducer${TRIAL}-||" | tr '\n' ',' | sed 's|,$||' | xargs -I {} echo "[${TRIAL}-{}] "`
      MATCHING_TRIALS+=("$MATCHING_TRIAL")
    done
    COUNT=`grep "   TEXT=" reducer* 2>/dev/null | sed 's|reducer\([0-9]\).sh:|reducer\1.sh:  |;s|reducer\([0-9][0-9]\).sh:|reducer\1.sh: |;s|  TEXT|TEXT|' | grep "${STRING}" | wc -l`
    STRING_OUT=`echo $STRING | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}${MATCHING_TRIALS[@]})"
  done
fi
IFS=$ORIG_IFS

# MODE 4 TRIALS
if [[ $PXC -eq 0 && $GRP_RPL -eq 0 ]]; then
  COUNT=0
  MATCHING_TRIALS=()
  for MATCHING_TRIAL in `grep -H "^MODE=4$" reducer* 2>/dev/null | awk '{print $1}' | sed 's|:.*||;s|[^0-9]||g' | sort -un` ; do
    if [ ! -r ${MATCHING_TRIAL}/SHUTDOWN_TIMEOUT_ISSUE ]; then
      MATCHING_TRIALS+=($MATCHING_TRIAL)
      COUNT=$[ COUNT + 1 ]
    fi
  done
  if [ $COUNT -gt 0 ]; then
    STRING_OUT=`echo "* TRIALS TO CHECK MANUALLY (NO TEXT SET: MODE=4) *" | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}$(echo ${MATCHING_TRIALS[@]}|sed 's| |,|g'))"
  fi
else
  COUNT=0
  MATCHING_TRIALS=()
  for TRIAL in `grep -H "^MODE=4$" reducer* 2>/dev/null | awk '{print $1}' | cut -d'-' -f1 | tr -d '[:alpha:]' | sort -un`; do
    MATCHING_TRIAL=`grep -H "^MODE=4$" reducer${TRIAL}-* 2>/dev/null | sed "s|.sh.*||;s|reducer${TRIAL}-||" | tr '\n' , | sed 's|,$||' | xargs -I '{}' echo "[${TRIAL}-{}] "`
    if [ ! -r ${MATCHING_TRIAL}/SHUTDOWN_TIMEOUT_ISSUE ]; then
      MATCHING_TRIALS+=($MATCHING_TRIAL)
      COUNT=$[ COUNT + 1 ]
    fi
  done
  if [ $COUNT -gt 0 ]; then
    STRING_OUT=`echo "* TRIALS TO CHECK MANUALLY (NO TEXT SET: MODE=4) *" | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}${MATCHING_TRIALS[@]})"
  fi
fi

# 'MySQL server has gone away' seen >= 200 times + timeout was not reached
if [ $(ls */GONEAWAY 2>/dev/null | wc -l) -gt 0 ]; then
  echo "--------------"
  echo "'MySQL server has gone away' trials found: $(ls */GONEAWAY | sed 's|/.*||' | tr '\n' ',' | sed 's|,$||')"
  echo "(> 'MySQL server has gone away' trials which did not hit the pquery timeout (i.e. the trial ended before pquery timeout was reached, hence something must have gone wrong) are not handled properly yet by pquery-prep-red.sh (feel free to expand it), and cannot be filtered easily (idem). Frequency also unkwnon. pquery-run.sh has only recently (26-08-2016) been expanded to not delete these. As they did not hit the pquery timeout, something must have gone wrong (in mysqld or in the pquery framework). Please check for existence of a core file (unlikely) and check the mysqld error log, the pquery logs and the SQL log, especially the last query before 'MySQL server has gone away' started happening. If it is a SELECT query on P_S, it's likely http://bugs.mysql.com/bug.php?id=82663 - a mysqld hang)"
fi

# 'SIGKILL myself' trials
if [ $(grep -l "SIGKILL myself" */log/master.err 2>/dev/null | wc -l) -gt 0 ]; then 
  echo "--------------"
  echo "'SIGKILL myself' trials found: $(grep -l "SIGKILL myself" */log/master.err 2>/dev/null | sed 's|/.*||' | tr '\n' ',' | sed 's|,$||')"
  echo "(> 'SIGKILL myself' trials are not handled properly yet by pquery-prep-red.sh (feel free to expand it), and cannot be filtered easily (idem). Frequency also unkwnon. pquery-run.sh has only recently (26-08-2016) been expanded to not delete these. Easiest way to handle these ftm is to set them to MODE=4 and TEXT='SIGKILL myself' in their reducer<trialnr>.sh files. Then, simply reduce as normal.)"
fi

# ASAN errors
if [ $(grep -l "ERROR:" */log/master.err 2>/dev/null | wc -l) -gt 0 ]; then 
  echo "--------------"
  echo "ASAN trials (or other 'ERROR:' issues) found and the issues seen:"
  grep "ERROR:" */log/master.err 2>/dev/null | sed 's|/log/master.err||'
  echo "(> ASAN trials are not handled properly yet by pquery-prep-red.sh (feel free to expand it), and cannot be filtered easily (idem). Frequency also unkwnon. pquery-run.sh has only recently (26-08-2016) been expanded to not delete these. Easiest way to handle these ftm is to set them to MODE=4 and TEXT='ERROR: <copy some limited detail from line above but NOT the addresses>' in their reducer<trialnr>.sh files. Then, simply reduce as normal.)"
fi

# mysqld shutdown issue trials
if [ $(ls */SHUTDOWN_TIMEOUT_ISSUE 2>/dev/null | wc -l) -gt 0 ]; then 
  echo "--------------"
  echo "'mysqld shutdown issue' trials found: $(ls */SHUTDOWN_TIMEOUT_ISSUE 2>/dev/null | sed 's|/.*||' | tr '\n' ',' | sed 's|,$||')"
  echo "(> The trials failed to shutdown properly within a timeframe of 90 seconds in the original run. Reduce as shutdown problems, unless a crash was found during the same trial also (i.e. it is listed above in the normal crash trials list also)."
fi

# MODE 2 TRIALS (Query correctness trials)
COUNT=`grep -l "^MODE=2$" qcreducer* 2>/dev/null | wc -l`
if [ $COUNT -gt 0 ]; then
  for STRING in `grep "   TEXT=" qcreducer* 2>/dev/null | sed 's|.*TEXT="||;s|"$||' | sort -u`; do
    MATCHING_TRIALS=()
    for TRIAL in `grep -H "${STRING}" qcreducer* 2>/dev/null | awk '{ print $1}' | cut -d'-' -f1 | sed 's/[^0-9]//g' | sort -un` ; do
      MATCHING_TRIAL=`grep -H "   TEXT=" qcreducer${TRIAL}* 2>/dev/null | sed 's!qcreducer\([0-9]\).sh:!qcreducer\1.sh:  !;s!qcreducer\([0-9][0-9]\).sh:!qcreducer\1.sh: !;s!  TEXT!TEXT!' | grep "${STRING}" | sed "s!.sh.*!!;s!reducer${TRIAL}!!" | tr '\n' ',' | sed 's!,$!!' | xargs -I {} echo "[${TRIAL}{}] " 2>/dev/null | sed 's!qc!!' `
      MATCHING_TRIALS+=("$MATCHING_TRIAL")
    done
    COUNT=`grep "   TEXT=" qcreducer* 2>/dev/null | sed 's|qcreducer\([0-9]\).sh:|qcreducer\1.sh:  |;s|qcreducer\([0-9][0-9]\).sh:|qcreducer\1.sh: |;s|  TEXT|TEXT|' | grep "${STRING}" | wc -l`
    STRING_OUT=`echo $STRING | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}${MATCHING_TRIALS[@]})"
  done
fi
echo "================"
echo -n "Coredumps found in trials: "
find . | grep core | grep -v parse | grep -v pquery | cut -d '/' -f2 | sort -nu | tr '\n' ' ' | sed 's|$|\n|'
echo "================"
if [ `ls -l reducer* qcreducer* 2>/dev/null | awk '{print $5"|"$9}' | grep "^0|" | sed 's/^0|//' | wc -l` -gt 0 ]; then
  echo "Detected one or more empty (0 byte) reducer script(s): `ls -l reducer* qcreducer* 2>/dev/null | awk '{print $5"|"$9}' | grep "^0|" | sed 's/^0|//' | tr '\n' ' '`- you may want to check what's causing this (possibly a bug in pquery-prep-red.sh, or did you simply run out of space while running pquery-prep-red.sh?) and do the analysis for these trial numbers manually, or free some space, delete the reducer*.sh scripts and re-run pquery-prep-red.sh"
fi

extract_valgrind_error(){
  for i in $( ls  */log/master.err 2>/dev/null); do
    TRIAL=`echo $i | cut -d'/' -f1`
    echo "============ Trial $TRIAL ===================="
    egrep --no-group-separator  -A4 "Thread[ \t][0-9]+:" $i | cut -d' ' -f2- |  sed 's/0x.*:[ \t]\+//' |  sed 's/(.*)//' | rev | cut -d '(' -f2- | sed 's/^[ \t]\+//' | rev  | sed 's/^[ \t]\+//'  |  tr '\n' '|' |xargs |  sed 's/Thread[ \t][0-9]\+:/\nIssue #/ig'
  done
}

if [ ! -z $1 ]; then
  extract_valgrind_error
fi
