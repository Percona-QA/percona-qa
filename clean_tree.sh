#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "${1}" != "1" ]; then
  echo "(!) Script not armed! To arm it, include the number 1 behind it, e.g.: $ ~/percona-qa/clean_tree.sh 1"
  echo "(!) Note that this script will reset this git directory to it's 'factory defaults'!"
  echo "(!) If you have made any changes, made any commits, or added any files, please save your work BEFORE running this!"
else
  git reset --hard
  git clean -xfd
  git pull
fi
