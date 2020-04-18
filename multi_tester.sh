#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# User configurable variables
TESTCASE=$1             # Best left as =$1, i.e. use the first option to this script as the testcase
TEST_MAX_DURATION=300   # Increase for large testcases
MEXTRA="--no-defaults"  # Default setting is ="--no-defaults", change below if necessary
#MYEXTRA="--no-defaults --sql_mode=ONLY_FULL_GROUP_BY"
#MYEXTRA="--no-defaults --sql_mode=ONLY_FULL_GROUP_BY --event-scheduler=ON"
#MYEXTRA="--no-defaults --event-scheduler=ON"

NAMEDIR1=PS-5.7-OPT;   TESTDIR1=/sda/PS-5.7-opt-alpha
NAMEDIR2=PS-5.7-DBG;   TESTDIR2=/sda/PS-5.7-debug-alpha
NAMEDIR3=MS-5.7-OPT;   TESTDIR3=/sda/mysql-5.7.8-rc-linux-glibc2.5-x86_64
NAMEDIR4=MS-5.7-DBG;   TESTDIR4=/sda/mysql-5.7.8-rc-linux-x86_64-debug
NAMEDIR5=PS-5.6-DBG;   TESTDIR5=/sda/Percona-Server-5.6.25-rel73.2-f9f2b02.Linux.x86_64-debug
NAMEDIR6=MS-5.6-DBG;   TESTDIR6=/sdc/mysql-5.6.23-linux-x86_64
NAMEDIR7=MS-5.7.5-OPT; TESTDIR7=/sda/MS-mysql-5.7.5-m15-linux-x86_64-opt
NAMEDIR8=MS-5.7.5-DBG; TESTDIR8=/sda/MS-mysql-5.7.5-m15-linux-x86_64-dbg

# Internal variables
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

if [ ! -r ${TESTDIR1}/init ];then echo "Assert: ${TESTDIR1}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR1}/init;fi
if [ ! -r ${TESTDIR2}/init ];then echo "Assert: ${TESTDIR2}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR2}/init;fi
if [ ! -r ${TESTDIR3}/init ];then echo "Assert: ${TESTDIR3}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR3}/init;fi
if [ ! -r ${TESTDIR4}/init ];then echo "Assert: ${TESTDIR4}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR4}/init;fi
if [ ! -r ${TESTDIR5}/init ];then echo "Assert: ${TESTDIR5}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR5}/init;fi
if [ ! -r ${TESTDIR6}/init ];then echo "Assert: ${TESTDIR6}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR6}/init;fi
if [ ! -r ${TESTDIR7}/init ];then echo "Assert: ${TESTDIR7}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR7}/init;fi
if [ ! -r ${TESTDIR8}/init ];then echo "Assert: ${TESTDIR8}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from the dir?";exit 1;else chmod +x ${TESTDIR8}/init;fi

if [ "${MYEXTRA}" != "--no-defaults" -a "${MYEXTRA}" != "" ]; then
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR1}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR1}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR2}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR2}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR3}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR3}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR4}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR4}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR5}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR5}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR6}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR6}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR7}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR7}/start
  sed -i 's|^[ \t]*MYEXTRA|#MYEXTRA|g' ${TESTDIR8}/start; sed -ie "1i\MYEXTRA=\" ${MYEXTRA} \"" ${TESTDIR8}/start
fi

rm ${TESTDIR1}/in.sql ${TESTDIR1}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR1}/in.sql; TESTD1=$(echo ${TESTDIR1} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR2}/in.sql ${TESTDIR2}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR2}/in.sql; TESTD2=$(echo ${TESTDIR2} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR3}/in.sql ${TESTDIR3}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR3}/in.sql; TESTD3=$(echo ${TESTDIR3} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR4}/in.sql ${TESTDIR4}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR4}/in.sql; TESTD4=$(echo ${TESTDIR4} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR5}/in.sql ${TESTDIR5}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR5}/in.sql; TESTD5=$(echo ${TESTDIR5} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR6}/in.sql ${TESTDIR6}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR6}/in.sql; TESTD6=$(echo ${TESTDIR6} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR7}/in.sql ${TESTDIR7}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR7}/in.sql; TESTD7=$(echo ${TESTDIR7} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')
rm ${TESTDIR8}/in.sql ${TESTDIR8}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR8}/in.sql; TESTD8=$(echo ${TESTDIR8} | sed 's|.*\(5\.[15678][\.0-9]*\).*|\1|g')

Go(){
  echo "======= ${1} (${2})"
  cd $3
  kill -9 $(ps -ef | grep ${PWD} | grep -v grep | awk '{print $2}') >/dev/null 2>&1
  sleep 0.2
  ./init >/dev/null 2>&1
  ./start >/dev/null 2>&1
  sleep 3
  timeout --signal=SIGKILL ${TEST_MAX_DURATION}s ./test >/dev/null 2>&1
  if [ $? -ge 124 ]; then echo "test run timed out. You may want to consider increasing TEST_MAX_DURATION or check what is going wrong"; fi
  tail mysql.out
  TEXT1="$(${SCRIPT_PWD}/text_string.sh ./log/master.err)"
  timeout --signal=SIGKILL 10s ./stop >/dev/null 2>&1
  TEXT2="$(${SCRIPT_PWD}/text_string.sh ./log/master.err)"
  if [ "${TEXT1}" != "" -a "${TEXT1}" == "${TEXT2}" ]; then echo "mysqld crash detected during replay: ${TEXT1}"; fi
  if [ "${TEXT1}" == "" -a "${TEXT2}" != "" ]; then echo "mysqld crash detected during shutdown: ${TEXT2}"; fi
}

Go ${NAMEDIR1} ${TESTD1} ${TESTDIR1}
Go ${NAMEDIR2} ${TESTD2} ${TESTDIR2}
Go ${NAMEDIR3} ${TESTD3} ${TESTDIR3}
Go ${NAMEDIR4} ${TESTD4} ${TESTDIR4}
Go ${NAMEDIR5} ${TESTD5} ${TESTDIR5}
Go ${NAMEDIR6} ${TESTD6} ${TESTDIR6}
Go ${NAMEDIR7} ${TESTD7} ${TESTDIR7}
Go ${NAMEDIR8} ${TESTD8} ${TESTDIR8}

