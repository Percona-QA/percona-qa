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
      sleep 0.3  # Small wait, then recheck (to avoid missed ps output)
      if [ $(ps -ef | grep -v grep | grep "${DIR}" | wc -l) -eq 0 ]; then
        sleep 0.3  # Small wait, then recheck (to avoid missed ps output)
        if [ $(ps -ef | grep -v grep | grep "${DIR}" | wc -l) -eq 0 ]; then
          AGE=$[ $(date +%s) - $(stat -c %Z ${DIR}) ]  # Directory age in seconds
          if [ ${AGE} -ge 60 ]; then  # Yet another safety, don't delete very recent directories
            echo "Deleting... ${DIR} (age: ${AGE} seconds)"
            COUNT_FOUND_AND_DEL=$[ ${COUNT_FOUND_AND_DEL} + 1 ]
            if [ ${ARMED} -eq 1 ]; then
              rm -Rf ${DIR}
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
