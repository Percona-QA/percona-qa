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
if [ $? -ne 0 ]; then
  echo "If you got an 'openBinaryFile: does not exist (No such file or directory)' error, it is due to snap not being able to access this directory. Please move or copy this script to your homedir and it will work, or use the apt version of shellscheck instead. Ref https://stackoverflow.com/q/63589562/1208218"
  exit 1
else
  if [ ${CHECKWARNINGS} -eq 1 ]; then
    echo "------------------ WARNINGS FOUND ----------------"
    shellcheck -s bash -S error ${1}
  fi
fi
