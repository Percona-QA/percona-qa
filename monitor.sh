#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SLEEP=10      # Sleep # seconds between status updates

echoit(){
  echo "[$(date +'%T')] $1"
}

while(true); do
  PROC_MD="$(ps -ef | grep mysqld | grep -o "\-\-pid-file=.*/pid.pid" | sort -u | wc -l)"
  PROC_RD="$(ps -ef | grep -v "grep" | egrep "reducer" | wc -l)"
  PROC_PQ="$(ps -ef | grep -v "grep" | egrep "pquery" | wc -l)"
  SPACE_T="$(df -h | egrep "/dev/shm" | awk '{print $4}')"
  SPACE_R="$(df -h | egrep "/$" | awk '{print $4}')"
  SPACE_S="$(df -h | egrep "/sd[a-z]$" | awk '{print $6"__"$4}' | sort | sed 's|/sd||;s|__|:|' | tr '\n' ' ' | sed 's| $||g')"
  MEMO_FR="$(free -h | head -n2 | tail -n1 | awk '{print $4}')"
  SWAP_FR="$(free -h | head -n3 | tail -n1 | awk '{print $4}')"
  LOAD_SY="$(uptime | sed 's|.*average: ||')"
  echoit "LOAD: avg: ${LOAD_SY} | mysqld's: ${PROC_MD} | reducer's: ${PROC_RD} | pquery's: ${PROC_PQ} || FREE: mem: ${MEMO_FR} | swap: ${SWAP_FR} | root: ${SPACE_R} | sd[a-z]: ${SPACE_S} | tmpfs: ${SPACE_T}"
  sleep ${SLEEP}
done
