#!/bin/bash
SET=0

if [ -r ~/mariadb-qa/known_bugs.strings ]; then
  if [ -r /test/TESTCASES/inprogress_known_bugs.strings ]; then
    cp ~/mariadb-qa/known_bugs.strings ~/mariadb-qa/known_bugs.strings.PREV
    cat /test/TESTCASES/inprogress_known_bugs.strings >> ~/mariadb-qa/known_bugs.strings
    SET=1
  fi
fi

~/mariadb-qa/pquery-clean-all.sh 

if [ ${SET} -eq 1 ]; then
  if [ -r ~/mariadb-qa/known_bugs.strings.PREV ]; then
    rm ~/mariadb-qa/known_bugs.strings
    mv ~/mariadb-qa/known_bugs.strings.PREV ~/mariadb-qa/known_bugs.strings
    echo "Please check contents of ~/mariadb-qa/known_bugs.strings which may have changed, if changes were made while this script was running. Easiest way to check:"
    echo "cd ~/mariadb-qa && git diff known_bugs.strings"
    exit 0
  else
    echo "Assert: SET=1 yet ~/mariadb-qa/known_bugs.strings.PREV was not found!"
    exit 1
  fi
fi
