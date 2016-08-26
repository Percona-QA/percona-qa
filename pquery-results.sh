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

# Current location checks
if [ `ls ./*/*.sql 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Assert: no pquery trials (with logging - i.e. ./*/*.sql) were found in this directory (or they were all cleaned up already)"
  echo "Please make sure to execute this script from within the pquery working directory!"
  exit 1
elif [ `ls ./reducer* ./qcreducer* 2>/dev/null | wc -l` -eq 0 ]; then
  echo "Assert: no reducer scripts were found in this directory. Did you forgot to execute ${SCRIPT_PWD}/pquery-prep-red.sh ?"
  exit 1
fi

TRIALS_EXECUTED=$(cat pquery-run.log 2>/dev/null | grep -o "==.*TRIAL.*==" | tail -n1 | sed 's|[^0-9]*||;s|[ \t=]||g')
echo "================ Sorted unique issue strings (${TRIALS_EXECUTED} trials executed, `ls reducer*.sh qcreducer*.sh 2>/dev/null | wc -l` remaining reducer scripts)"
ORIG_IFS=$IFS; IFS=$'\n'  # Use newline seperator instead of space seperator in the for loop
if [ $PXC == 0 ]; then
  for STRING in `grep "   TEXT=" reducer* 2>/dev/null | sed 's|.*TEXT="||;s|"$||' | sort -u`; do
    COUNT=`grep "   TEXT=" reducer* 2>/dev/null | sed 's|reducer\([0-9]\).sh:|reducer\1.sh:  |;s|reducer\([0-9][0-9]\).sh:|reducer\1.sh: |;s|  TEXT|TEXT|' | grep "${STRING}" | wc -l`
    MATCHING_TRIALS=`grep -H "   TEXT=" reducer* 2>/dev/null | sed 's|reducer\([0-9]\).sh:|reducer\1.sh:  |;s|reducer\([0-9][0-9]\).sh:|reducer\1.sh: |;s|  TEXT|TEXT|' | grep "${STRING}" | sed 's|.sh.*||;s|reducer||' | tr '\n' ',' | sed 's|,$||'`
    STRING_OUT=`echo $STRING | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}${MATCHING_TRIALS})"
  done
else
  for STRING in `grep "   TEXT=" reducer* 2>/dev/null | sed 's|.*TEXT="||;s|"$||' | sort -u`; do
    MATCHING_TRIALS=()
    for TRIAL in `grep -H ${STRING} reducer* 2>/dev/null | awk '{ print $1}' | cut -d'-' -f1 | tr -d '[:alpha:]' | uniq` ; do
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
if [ $PXC == 0 ]; then
  COUNT=`grep -l "^MODE=4$" reducer* 2>/dev/null | wc -l`
  if [ $COUNT -gt 0 ]; then
    MATCHING_TRIALS=`grep -l "^MODE=4$" reducer* 2>/dev/null | tr -d '\n' | sed 's|reducer|,|g;s|[.sh]||g;s|^,||'`
    STRING_OUT=`echo "* TRIALS TO CHECK MANUALLY (NO TEXT SET: MODE=4) *" | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}${MATCHING_TRIALS})"
  fi
else
  COUNT=`grep -l "^MODE=4$" reducer* 2>/dev/null | wc -l`
  if [ $COUNT -gt 0 ]; then
    MATCHING_TRIALS=()
    for TRIAL in `grep -H "^MODE=4$" reducer* 2>/dev/null | awk '{ print $1}' | cut -d'-' -f1 | tr -d '[:alpha:]' | uniq` ; do
      MATCHING_TRIAL=`grep -H "^MODE=4$" reducer${TRIAL}-* 2>/dev/null | sed "s|.sh.*||;s|reducer${TRIAL}-||" | tr '\n' , | sed 's|,$||' | xargs -I '{}' echo "[${TRIAL}-{}] "`
      MATCHING_TRIALS+=("$MATCHING_TRIAL")
    done
    STRING_OUT=`echo "* TRIALS TO CHECK MANUALLY (NO TEXT SET: MODE=4) *" | awk -F "\n" '{printf "%-55s",$1}'`
    COUNT_OUT=`echo $COUNT | awk '{printf "(Seen %3s times: reducers ",$1}'`
    echo -e "${STRING_OUT}${COUNT_OUT}${MATCHING_TRIALS[@]})"
  fi
fi
# 'SIGKILL myself' TRIALS
if [ $(grep -l "SIGKILL myself" */log/master.err 2>/dev/null | wc -l) -gt 0 ]; then 
  echo "--------------"
  echo "'SIGKILL myself' TRIALS found: $(grep -l "SIGKILL myself" */log/master.err 2>/dev/null | sed 's|/.*||' | tr '\n' ' ')"
  echo "(> 'SIGKILL myself' trials are not handled properly yet by pquery-prep-red.sh (feel free to expand it), and cannot be filtered easily (idem). Frequency also unkwnon. pquery-run.sh has only recently (26-08-2016) been expanded to not delete these. Easiest way to handle these ftm is to set them to MODE=4 and TEXT='SIGKILL myself' in their reducer<trialnr>.sh files. Then, simply reduce as normal.)"
fi
# ASAN errors
grep "ERROR:" */log/master.err
if [ $(grep -l "ERROR:" */log/master.err 2>/dev/null | wc -l) -gt 0 ]; then 
  echo "--------------"
  echo "ASAN TRIALS found: $(grep -l "ERROR:" */log/master.err 2>/dev/null | sed 's|/.*||' | tr '\n' ' ')"
  echo "(> ASAN trials are not handled properly yet by pquery-prep-red.sh (feel free to expand it), and cannot be filtered easily (idem). Frequency also unkwnon. pquery-run.sh has only recently (26-08-2016) been expanded to not delete these. Easiest way to handle these ftm is to set them to MODE=4 and TEXT='ERROR: <copy some limited detail from log>' in their reducer<trialnr>.sh files. Then, simply reduce as normal.)"
fi
# MODE 2 TRIALS (Query correctness trials)
COUNT=`grep -l "^MODE=2$" qcreducer* 2>/dev/null | wc -l`
if [ $COUNT -gt 0 ]; then
  for STRING in `grep "   TEXT=" qcreducer* 2>/dev/null | sed 's|.*TEXT="||;s|"$||' | sort -u`; do
    MATCHING_TRIALS=()
    for TRIAL in `grep -H ${STRING} qcreducer* 2>/dev/null | awk '{ print $1}' | cut -d'-' -f1 | sed 's/[^0-9]//g' | uniq` ; do
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
if [ `ls -l reducer* qcreducer* 2>/dev/null | awk '{print $5"|"$9}' | grep "^0|" | sed 's/^0|//' | wc -l` -gt 0 ]; then
  echo "Detected some empty (0 byte) reducer scripts: `ls -l reducer* qcreducer* 2>/dev/null | awk '{print $5"|"$9}' | grep "^0|" | sed 's/^0|//' | tr '\n' ' '`- you may want to check what's causing this (possibly a bug in pquery-prep-red.sh, or did you simply run out of space while running pquery-prep-red.sh?) and do the analysis for these trial numbers manually, or free some space, delete the reducer*.sh scripts and re-run pquery-prep-red.sh"
fi

extract_valgrind_error(){
  for i in $( ls  */log/master.err ); do
    TRIAL=`echo $i | cut -d'/' -f1`
    echo "============ Trial $TRIAL ===================="
    egrep --no-group-separator  -A4 "Thread[ \t][0-9]+:" $i | cut -d' ' -f2- |  sed 's/0x.*:[ \t]\+//' |  sed 's/(.*)//' | rev | cut -d '(' -f2- | sed 's/^[ \t]\+//' | rev  | sed 's/^[ \t]\+//'  |  tr '\n' '|' |xargs |  sed 's/Thread[ \t][0-9]\+:/\nIssue #/ig'
  done
}

if [ ! -z $1 ]; then
  extract_valgrind_error
fi
