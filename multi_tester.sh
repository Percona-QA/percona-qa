#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# User configurable variables
TESTCASE=$1

NAMEDIR1=PS-5.7-OPT; TESTDIR1=/sda/PS-5.7-opt-alpha
NAMEDIR2=PS-5.7-DBG; TESTDIR2=/sda/PS-5.7-debug-alpha
NAMEDIR3=MS-5.7-OPT; TESTDIR3=/sda/mysql-5.7.8-rc-linux-glibc2.5-x86_64
NAMEDIR4=MS-5.7-DBG; TESTDIR4=/sda/mysql-5.7.8-rc-linux-x86_64-debug
NAMEDIR5=PS-5.6-DBG; TESTDIR5=/sda/Percona-Server-5.6.25-rel73.2-f9f2b02.Linux.x86_64-debug
NAMEDIR6=MS-5.6-DBG; TESTDIR6=/sdc/mysql-5.6.23-linux-x86_64

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

if [ ! -r ${TESTDIR1}/init ];then echo "Assert: ${TESTDIR1}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from this dir?";exit 1;else chmod +x ${TESTDIR1}/init;fi
if [ ! -r ${TESTDIR2}/init ];then echo "Assert: ${TESTDIR2}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from this dir?";exit 1;else chmod +x ${TESTDIR2}/init;fi
if [ ! -r ${TESTDIR3}/init ];then echo "Assert: ${TESTDIR3}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from this dir?";exit 1;else chmod +x ${TESTDIR3}/init;fi
if [ ! -r ${TESTDIR4}/init ];then echo "Assert: ${TESTDIR4}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from this dir?";exit 1;else chmod +x ${TESTDIR4}/init;fi
if [ ! -r ${TESTDIR5}/init ];then echo "Assert: ${TESTDIR5}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from this dir?";exit 1;else chmod +x ${TESTDIR5}/init;fi
if [ ! -r ${TESTDIR6}/init ];then echo "Assert: ${TESTDIR6}/init not found! Did you forget to run ${SCRIPT_PWD}/startup.sh from this dir?";exit 1;else chmod +x ${TESTDIR6}/init;fi

rm ${TESTDIR1}/in.sql ${TESTDIR1}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR1}/in.sql
rm ${TESTDIR2}/in.sql ${TESTDIR2}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR2}/in.sql
rm ${TESTDIR3}/in.sql ${TESTDIR3}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR3}/in.sql
rm ${TESTDIR4}/in.sql ${TESTDIR4}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR4}/in.sql
rm ${TESTDIR5}/in.sql ${TESTDIR5}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR5}/in.sql
rm ${TESTDIR6}/in.sql ${TESTDIR6}/mysql.out >/dev/null 2>&1; cp ${TESTCASE} ${TESTDIR6}/in.sql

echo "============ ${NAMEDIR1}";cd $TESTDIR1;./init >/dev/null 2>&1;./start >/dev/null 2>&1;sleep 3;./test;tail mysql.out;./stop >/dev/null 2>&1
echo "============ ${NAMEDIR2}";cd $TESTDIR2;./init >/dev/null 2>&1;./start >/dev/null 2>&1;sleep 3;./test;tail mysql.out;./stop >/dev/null 2>&1
echo "============ ${NAMEDIR3}";cd $TESTDIR3;./init >/dev/null 2>&1;./start >/dev/null 2>&1;sleep 3;./test;tail mysql.out;./stop >/dev/null 2>&1
echo "============ ${NAMEDIR4}";cd $TESTDIR4;./init >/dev/null 2>&1;./start >/dev/null 2>&1;sleep 3;./test;tail mysql.out;./stop >/dev/null 2>&1
echo "============ ${NAMEDIR5}";cd $TESTDIR5;./init >/dev/null 2>&1;./start >/dev/null 2>&1;sleep 3;./test;tail mysql.out;./stop >/dev/null 2>&1
echo "============ ${NAMEDIR6}";cd $TESTDIR6;./init >/dev/null 2>&1;./start >/dev/null 2>&1;sleep 3;./test;tail mysql.out;./stop >/dev/null 2>&1
