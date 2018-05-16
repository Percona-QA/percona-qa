#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "${1}" != "1" ]; then
  echo "(!) Script not armed! To arm it, include the number 1 behind it, e.g.: $ ~/percona-qa/tmpfs_clean.sh 1"
  echo "(!) This will enable actual tmpfs cleanup. Now executing a trial run only - no actual changes are made!"
  ARMED=0
else
  ARMED=1
fi

COUNT_FOUND_AND_DEL=0
COUNT_FOUND_AND_NOT_DEL=0
if [ $(ls -ld /dev/shm/* | wc -l) -eq 0 ]; then
  echo "> No /dev/shm/* directories found at all, it looks like tmpfs is empty. All good."
  exit 0
else
  for DIR in $(ls -ld /dev/shm/* | sed 's|^.*/dev/shm|/dev/shm|'); do
    if [ $(ps -ef | grep -v grep | grep "${DIR}" | wc -l) -eq 0 ]; then
      sync; sleep 0.3  # Small wait, then recheck (to avoid missed ps output)
      if [ $(ps -ef | grep -v grep | grep "${DIR}" | wc -l) -eq 0 ]; then
        sync; sleep 0.3  # Small wait, then recheck (to avoid missed ps output)
        if [ $(ps -ef | grep -v grep | grep "${DIR}" | wc -l) -eq 0 ]; then
          AGEDIR=$[ $(date +%s) - $(stat -c %Z ${DIR}) ]  # Directory age in seconds
          if [ ${AGEDIR} -ge 90 ]; then  # Yet another safety, don't delete very recent directories
            if [ -r ${DIR}/reducer.log ]; then
              AGEFILE=$[ $(date +%s) - $(stat -c %Z ${DIR}/reducer.log) ]  # File age in seconds
              if [ ${AGEFILE} -ge 90 ]; then  # Yet another safety specifically for often-occuring reducer directories, don't delete very recent reducers
                echo "Deleting reducer directory ${DIR} (directory age: ${AGEDIR}s, file age: ${AGEFILE}s)"
                COUNT_FOUND_AND_DEL=$[ ${COUNT_FOUND_AND_DEL} + 1 ]
                if [ ${ARMED} -eq 1 ]; then rm -Rf ${DIR}; fi
              fi
            else
              DIRNAME=$(echo ${DIR} | sed 's|.*/||')
              if [ "$(echo ${DIRNAME} | sed 's|[0-9][0-9][0-9][0-9][0-9][0-9]||')" == "" ]; then  # 6 Numbers subdir; this is likely a pquery-run.sh generated directory
                SUBDIRCOUNT=$(ls ${DIR} 2>/dev/null | wc -l)  # Number of trial subdirectories
                if [ ${SUBDIRCOUNT} -le 1 ]; then  # pquery-run.sh directories generally have 1 (or 0 when in between trials) subdirectories. Both 0 and 1 need to be covered
                  SUBDIR=$(ls ${DIR} 2>/dev/null | sed 's|^|${DIR}/|')
                  if [ "${SUBDIR}" == "" ]; then  # Script may have caught a snapshot in-between pquery-run.sh trials
                    sync; sleep 3  # Delay (to provide pquery-run.sh (if running) time to generate new trial directory), then recheck
                    SUBDIR=$(ls ${DIR} 2>/dev/null | sed 's|^|${DIR}/|')
                  fi
                  AGESUBDIR=$[ $(date +%s) - $(stat -c %Z ${SUBDIR}) ]  # Current trial directory age in seconds
                  if [ ${AGESUBDIR} -ge 10800 ]; then  # Don't delete pquery-run.sh directories if they have recent trials in them (i.e. they are likely still running): >=3hr
                    echo "Deleting directory ${DIR} (trial subdirectory age: ${AGESUBDIR}s)"
                    COUNT_FOUND_AND_DEL=$[ ${COUNT_FOUND_AND_DEL} + 1 ]
                    if [ ${ARMED} -eq 1 ]; then rm -Rf ${DIR}; fi
                  fi
                fi
              else
                echo "Deleting directory ${DIR} (directory age: ${AGEDIR}s)"
                COUNT_FOUND_AND_DEL=$[ ${COUNT_FOUND_AND_DEL} + 1 ]
                if [ ${ARMED} -eq 1 ]; then rm -Rf ${DIR}; fi
              fi
            fi
          fi
        fi
      fi
    else
      COUNT_FOUND_AND_NOT_DEL=$[ ${COUNT_FOUND_AND_NOT_DEL} + 1 ]
    fi
  done
  if [ ${COUNT_FOUND_AND_NOT_DEL} -ge 1 -a ${COUNT_FOUND_AND_DEL} -eq 0 ]; then
    echo "> Though $(ls -ld /dev/shm/* | wc -l) tmpfs directories were found on /dev/shm, they are all in use. Nothing was deleted."
  else
    if [ ${COUNT_FOUND_AND_DEL} -gt 0 ]; then
      echo "> Deleted ${COUNT_FOUND_AND_DEL} tmpfs directories & skipped ${COUNT_FOUND_AND_NOT_DEL} tmpfs directories as they were in use."
    else
      echo "> Deleted ${COUNT_FOUND_AND_DEL} tmpfs directories. No other tmpfs directories exist. All good."
    fi
  fi
fi

echo "> Done! /dev/shm available space is now: $(df -h | egrep "/dev/shm" | awk '{print $4}')"
