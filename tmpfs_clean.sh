#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "${1}" != "1" ]; then
  echo "(!) Script not armed! To arm it, include the number 1 behind it, e.g.: $ ~/mariadb-qa/tmpfs_clean.sh 1"
  echo "(!) This will enable actual tmpfs cleanup. Now executing a trial run only - no actual changes are made!"
  ARMED=0
else
  ARMED=1
fi

COUNT_FOUND_AND_DEL=0
COUNT_FOUND_AND_NOT_DEL=0
if [ $(ls --color=never -ld /dev/shm/* | wc -l) -eq 0 ]; then
  echo "> No /dev/shm/* directories found at all, it looks like tmpfs is empty. All good."
else
  rm -f /tmp/tmpfs_clean_dirs
  ls --color=never -ld /dev/shm/* | sed 's|^.*/dev/shm|/dev/shm|' >/tmp/tmpfs_clean_dirs 2>/dev/null
  COUNT=$(wc -l /tmp/tmpfs_clean_dirs 2>/dev/null | sed 's| .*||')
  for DIRCOUNTER in $(seq 1 ${COUNT}); do
    DIR="$(head -n ${DIRCOUNTER} /tmp/tmpfs_clean_dirs | tail -n1)"
    STORE_COUNT_FOUND_AND_DEL=${COUNT_FOUND_AND_DEL}
    if [ -d ${DIR} ]; then  # Ensure it's a directory (avoids deleting pquery-reach.log for example)
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
                if [ "$(echo ${DIRNAME} | sed 's|[0-9][0-9][0-9][0-9][0-9][0-9]||' | sed 's|[0-9][0-9][0-9][0-9][0-9][0-9][0-9]||')" == "" ]; then  # 6 or 7 Numbers subdir; this is likely a pquery-run.sh (6) or pquery-reach.sh (7) generated directory
                  SUBDIRCOUNT=$(ls --color=never -dF ${DIR}/* 2>/dev/null | grep \/$ | sed 's|/$||' | wc -l)  # Number of trial subdirectories
                  if [ ${SUBDIRCOUNT} -le 1 ]; then  # pquery-run.sh directories generally have 1 (or 0 when in between trials) subdirectories. Both 0 and 1 need to be covered
                    if [ $(ls ${DIR}/*pquery*reach* 2>/dev/null | wc -l) -gt 0 ]; then # A pquery-reach.sh directory
                      PR_FILE_TO_CHECK=$(ls --color=never ${DIR}/*pquery*reach* 2>/dev/null | head -n1)  # Head -n1 is defensive, there should be only 1 file
                      if [ -z ${PR_FILE_TO_CHECK} ]; then 
                        echo "Assert: \$PR_FILE_TO_CHECK empty"
                        exit 1
                      fi
                      AGEFILE=$(( $(date +%s) - $(stat -c %Z "${PR_FILE_TO_CHECK}")))  # File age in seconds 
                      if [ ${AGEFILE} -ge 1200 ]; then  # Delete pquery-reach.sh directories aged >=20 minutes
                        echo "Deleting pquery-reach.sh directory ${DIR} (pquery-reach log age: ${AGEFILE}s)"
                        COUNT_FOUND_AND_DEL=$[ ${COUNT_FOUND_AND_DEL} + 1 ]
                        if [ ${ARMED} -eq 1 ]; then rm -Rf ${DIR}; fi
                      fi
                    else
                      SUBDIR=$(ls --color=never -dF ${DIR}/* 2>/dev/null | grep \/$ | sed 's|/$||')
                      for i in `seq 1 3`; do  # Try 3 times
                        if [ "${SUBDIR}" == "" ]; then  # Script may have caught a snapshot in-between pquery-run.sh trials
                          sync; sleep 3  # Delay (to provide pquery-run.sh (if running) time to generate new trial directory), then recheck
                          SUBDIR=$(ls --color=never -dF ${DIR}/* 2>/dev/null | grep \/$ | sed 's|/$||')
                        else
                          break
                        fi
                      done
                      if [ -z "${SUBDIR}" ]; then  # No subdir, if directory exists, then it is empty
                        if [ -d ${DIR} ]; then
                          rmdir ${DIR}
                        else
                          echo "Assert: script saw directory ${DIR} yet was unable to find any subdir in it, please check the contents of ls -la ${DIR} and improve script in this area."
                          exit 1
                        fi
                      else
echo ${SUBDIR}
                        AGESUBDIR=$(( $(date +%s) - $(stat -c %Z "${SUBDIR}") ))  # Current trial directory age in seconds
                        if [ ${AGESUBDIR} -ge 10800 ]; then  # Don't delete pquery-run.sh directories if they have recent trials in them (i.e. they are likely still running): >=3hr
                          echo "Deleting directory ${DIR} (trial subdirectory age: ${AGESUBDIR}s)"
                          COUNT_FOUND_AND_DEL=$[ ${COUNT_FOUND_AND_DEL} + 1 ]
                          if [ ${ARMED} -eq 1 ]; then rm -Rf ${DIR}; fi
                        fi
                      fi
                    fi
                  else
                    echo "Unrecognized directory structure: ${DIR} (Assert: >=1 sub directories found, not covered yet, please fixme)"
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
      fi
    fi
    if [ ${STORE_COUNT_FOUND_AND_DEL} -eq ${COUNT_FOUND_AND_DEL} ]; then  # A directory was found but not deleted
      COUNT_FOUND_AND_NOT_DEL=$[ ${COUNT_FOUND_AND_NOT_DEL} + 1 ] 
    fi; STORE_COUNT_FOUND_AND_DEL=
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
exit 0

# With thanks, https://linoxide.com/linux-command/linux-commad-to-list-directories-directory-names-only/
