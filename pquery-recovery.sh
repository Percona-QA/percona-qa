#!/bin/bash

PQUERY_PWD=${PWD}
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
$PQUERY_PWD/$TRIAL/start_recovery > /dev/null &
BASEDIR=`grep BASEDIR $PQUERY_PWD/$TRIAL/start_recovery |  sed 's|^[ \t]*BASEDIR[ \t]*=[ \t]*[ \t]*||'`
for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  if ${BASEDIR}/bin/mysqladmin -urecovery -S${PQUERY_PWD}/${TRIAL}/socket.sock ping > /dev/null 2>&1; then
    break
  fi
done

# Check server startup
if egrep --binary-files=text -qi "registration as a STORAGE ENGINE failed" $PQUERY_PWD/$TRIAL/log/master.err; then
  echo "Recovery error : Storage engine registration failed:"
  egrep --binary-files=text -i "registration as a STORAGE ENGINE failed" $PQUERY_PWD/$TRIAL/log/master.err
  exit 1
elif egrep --binary-files=text -qi "corrupt|crashed" $PQUERY_PWD/$TRIAL/log/master.err; then
  echo "Recovery error : Log message '$_' indicates database corruption:"
  egrep --binary-files=text -i "corrupt|crashed" $PQUERY_PWD/$TRIAL/log/master.err
  exit 1
elif egrep --binary-files=text -qi "device full error|no space left on device|errno[:]* enospc|can't write.*bytes|errno[:]* 28|mysqld: disk full|waiting for someone to free some space|out of disk space|innodb: error while writing|bytes should have been written|error number[:]* 28|error[:]* 28" $PQUERY_PWD/$TRIAL/log/master.err
  echo "Recovery error : Check disk space:"
  egrep --binary-files=text -i "device full error|no space left on device|errno[:]* enospc|can't write.*bytes|errno[:]* 28|mysqld: disk full|waiting for someone to free some space|out of disk space|innodb: error while writing|bytes should have been written|error number[:]* 28|error[:]* 28" $PQUERY_PWD/$TRIAL/log/master.err
  exit 1
elif egrep --binary-files=text -qi "got error.*when reading table|got error.*from storage engine" $PQUERY_PWD/$TRIAL/log/master.err; then
  echo "Recovery error : Log message '$_' indicates database corruption:"
  egrep --binary-files=text -i "got error.*when reading table|got error.*from storage engine" $PQUERY_PWD/$TRIAL/log/master.err
  exit 1
elif egrep --binary-files=text -qi "ready for connections" $PQUERY_PWD/$TRIAL/log/master.err; then
  echo "Recovery info : Server Recovery was apparently successful."
fi

dbs=$(${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse "select schema_name from information_schema.schemata where schema_name not in ('mysql','information_schema','performance_schema')" )
# Check tables
for i in "${dbs[@]}"; do
  tbs=$(${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse "select table_name from information_schema.tables where table_schema='$i'")
  tbl_array=( $( for i in $tbs ; do echo $i ; done ) )
  for j in "${tbl_array[@]}"; do
    echo -e "\nVerifying table: $j; database: $i\n"
    chk_result=$((${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse $i "CHECK TABLE $j EXTENDED") 2>&1)
    analyze_result=$((${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse $i "ANALYZE TABLE $j") 2>&1)
    opt_result=$((${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse $i "OPTIMIZE TABLE $j") 2>&1)
    repair_result=$((${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse $i "REPAIR TABLE $j EXTENDED") 2>&1)
    alter_result=$((${BASEDIR}/bin/mysql --socket=${PQUERY_PWD}/${TRIAL}/socket.sock -urecovery -Bse $i "ALTER TABLE $j ENGINE = TokuDB") 2>&1)
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

