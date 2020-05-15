#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

if [ "$1" == "" ]; then
  echo "Error: please specify the workdir number (for example '123456') in /sda to run pquery-go-expert.sh against. Terminating."
  exit 1
else
  if [ ! -d "/sda/$1" ]; then
    echo "Error: the directory /sda/$1 does not exist!"
    exit 1
  else
    #screen -admS pge$1 bash -c "ulimit -u 4000;cd /sda/$1;${SCRIPT_PWD}/pquery-go-expert.sh;bash"
    screen -admS pge$1 bash -c "cd /sda/$1;${SCRIPT_PWD}/pquery-go-expert.sh;bash"
    screen -d -r pge$1
  fi
fi
