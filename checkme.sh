#!/bin/bash
# Created by Roel Van de Paar, MariaDB

CHECKWARNINGS=1

if [ -z "$(whereis shellcheck | awk '{print $2}')" ]; then
  sudo snap install shellcheck
fi

if [ -z "${1}" ]; then
  echo "Please indicate which script you would like to check, as the first option to this script!"
  exit 1
fi

echo "------------------ ERRORS FOUND ------------------"
shellcheck -s bash -S error ${1}

if [ ${CHECKWARNINGS} -eq 1 ]; then
  echo "------------------ WARNINGS FOUND ----------------"
  shellcheck -s bash -S error ${1}
fi
