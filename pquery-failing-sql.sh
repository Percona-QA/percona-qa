#!/bin/bash

# Internal variables
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
WORKD_PWD=$PWD

#Checking TRIAL number
if [ "" == "$1" ]; then
  echo "This script expects one parameter: the trial number to extract failing queries"
  echo "Please execute this script from within pquery's working/run directory"
  exit 1
else
  TRIAL=$1
fi

failing_queries_core(){
  rm -Rf ${WORKD_PWD}/$TRIAL/gdb_PARSE.txt
  cat ${SCRIPT_PWD}/extract_query.gdb | sed "s|file /tmp/gdb_PARSE.txt|file ${WORKD_PWD}/$TRIAL/gdb_PARSE.txt|" > ${WORKD_PWD}/$TRIAL/extract_query.gdb
  # For debugging purposes, remove ">/dev/null" on the next line and observe output
  gdb ${BIN} ${CORE} >/dev/null 2>&1 < ${WORKD_PWD}/$TRIAL/extract_query.gdb
  # The double quotes ; ; are to prevent parsing mishaps where the query is invalid and has opened a multi-line situation
  grep '^\$' ${WORKD_PWD}/$TRIAL/gdb_PARSE.txt | sed 's/^[\$0-9a-fx =]*"//;s/"$//;s/[ \t]*$//;s|\\"|"|g;s/$/; ;/' | grep -v '^\$' >> ${WORKD_PWD}/$TRIAL/${TRIAL}.sql.failing
}

failing_queries_error_log(){
  # The double quotes ; ; are to prevent parsing mishaps where the query is invalid and has opened a multi-line situation
  FAILING_QUERY_ERR=$(grep "Query ([x0-9a-fA-F]*):" $ERRLOG | sed 's|^Query ([x0-9a-fA-F]*): ||;s|$|; ;|')
  if [ "$(echo ${FAILING_QUERY_ERR} | sed 's|: [0-9]\+|: 0|')" != "Connection ID (thread ID): 0; ;" ]; then  # http://bugs.mysql.com/bug.php?id=81651
    echo "${FAILING_QUERY_ERR}" >> ${WORKD_PWD}/$TRIAL/${TRIAL}.sql.failing
  else
    echo "SELECT 1;" >> ${WORKD_PWD}/$TRIAL/${TRIAL}.sql.failing
  fi
}

# Second parameter is used only by the pquery-prep-red.sh script. If it is used, we know this is a pquery-prep-red.sh run
if [ "$2" == "1" ]; then
  failing_queries_core
elif [ "$2" == "2" ]; then
  failing_queries_error_log
else  # Script is being manually executed, not via pquery-prep-red.sh
  rm -Rf ${WORKD_PWD}/$TRIAL/${TRIAL}.sql.failing
  ERRLOG="${WORKD_PWD}/${TRIAL}/log/master.err"
  BIN=`ls -1 ${WORKD_PWD}/mysqld/mysqld 2>&1 | head -n1 | grep -v "No such file"`
  if [ ! -r $BIN ]; then
    echo "Assert! mysqld binary '$BIN' could not be read"
    exit 1
  fi
  CORE=`ls -1 ${WORKD_PWD}/${TRIAL}/data/*core* 2>&1 | head -n1 | grep -vE "No such file|Not a directory"`
  if [ "${CORE}" == "" ]; then echo "Assert! coredump '$CORE' could not be read"; exit 1; fi
  if [ ! -r $CORE ]; then echo "Assert! coredump '$CORE' could not be read"; exit 1; fi
  failing_queries_core
  failing_queries_error_log
  echo "Saved failing queries in ${WORKD_PWD}/$TRIAL/${TRIAL}.sql.failing"
fi
