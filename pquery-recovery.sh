#!/bin/bash

SCRIPT_PWD=$(cd `dirname $0` && pwd)
MYSQLD_START_TIMEOUT=60
if [ -z $1 ]; then
  echo "No valid parameter passed. Need relative trial directoy setting. Retry.";
  echo "Usage example:"
  echo "$./pquery-recovery.sh 100 "
  exit 1
else
  TRIAL=$1
fi
ps -ef | grep $TRIAL |grep mysqld | grep -v grep | awk '{print $2}' | xargs kill -9 > /dev/null 2>&1

# Start mysqld for recovery testing
$SCRIPT_PWD/$TRIAL/start_recovery > /dev/null &
BASEDIR=`grep BASEDIR $SCRIPT_PWD/$TRIAL/start_recovery |  sed 's|^[ \t]*BASEDIR[ \t]*=[ \t]*[ \t]*||'`
for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  if ${BASEDIR}/bin/mysqladmin -uroot -S${SCRIPT_PWD}/${TRIAL}/socket.sock ping > /dev/null 2>&1; then
    break
  fi
done

# Check server startup
if egrep -q  "registration as a STORAGE ENGINE failed" $SCRIPT_PWD/$TRIAL/log/master.err; then
  echo "Recovery error : Storage engine registration failed."
elif egrep -q  "corrupt|crashed" $SCRIPT_PWD/$TRIAL/log/master.err; then
  echo "Recovery error : Log message '$_' indicates database corruption."
elif egrep -q  "device full error|no space left on device" $SCRIPT_PWD/$TRIAL/log/master.err; then
  echo "Recovery error : Check disk space."
elif egrep -q  "ready for connections" $SCRIPT_PWD/$TRIAL/log/master.err; then
  echo "Recovery info : Server Recovery was apparently successful."
fi

dbs=$(${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse "select schema_name from information_schema.schemata where schema_name not in ('mysql','information_schema','performance_schema')" )
# Check tables
for i in "${dbs[@]}"; do
  tbs=$(${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse "select table_name from information_schema.tables where table_schema='$i'")
  tbl_array=( $( for i in $tbs ; do echo $i ; done ) )
  for j in "${tbl_array[@]}"; do
    echo -e "\nVerifying table: $j; database: $i\n"
    chk_result=$((${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse $i "CHECK TABLE $j EXTENDED") 2>&1)
    analyze_result=$((${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse $i "ANALYZE TABLE $j") 2>&1)
    opt_result=$((${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse $i "OPTIMIZE TABLE $j") 2>&1)
    repair_result=$((${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse $i "REPAIR TABLE $j EXTENDED") 2>&1)
    alter_result=$((${BASEDIR}/bin/mysql --socket=${SCRIPT_PWD}/${TRIAL}/socket.sock -uroot -Bse $i "ALTER TABLE $j ENGINE = TokuDB") 2>&1)
    ERROR_INFO=""
    if echo $chk_result| egrep -q -i "error|corrupt|repaired|invalid|crashed" ; then
      ERROR_INFO="Check table error : $chk_result\n"
    fi
    if echo $analyze_result| egrep -q -i "error|corrupt|repaired|invalid|crashed" ; then
      ERROR_INFO="${ERROR_INFO}Analyze table error : $analyze_result\n"
    fi
    if echo $opt_result| egrep -q -i "error|corrupt|repaired|invalid|crashed" ; then
      ERROR_INFO="${ERROR_INFO}Optimize table error : $opt_result\n"
    fi
    if echo $repair_result| egrep -q -i "error|corrupt|repaired|invalid|crashed" ; then
      ERROR_INFO="${ERROR_INFO}Repair table error : $repair_result\n"
    fi
    if echo $alter_result| egrep -q -i "error|corrupt|repaired|invalid|crashed" ; then
      ERROR_INFO="${ERROR_INFO}Alter table error : $alter_result\n"
    fi
    echo -e "$ERROR_INFO\n"
  done
done

