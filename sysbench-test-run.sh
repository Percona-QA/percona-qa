#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC
# This script is for sysbench test run

# User Configurable Variables
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
SYSBENCH_PATH=$WORKDIR/
PS_START_TIMEOUT=200
RPORT=$((( RANDOM%21 + 10 ) * 1000 ))
rm -rf $WORKDIR/logs; mkdir $WORKDIR/logs
cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

SYSBENCH_TAR=`ls -1td sysbench*.tar.gz | grep ".tar" | head -n1`

if [ ! -z $SYSBENCH_TAR ];then
  tar -xzf $SYSBENCH_TAR
  SYSBENCH_SOURCE=`ls -1td sysbench-* | grep -v ".tar" | head -n1`
fi

pushd $SYSBENCH_SOURCE
./autogen.sh
./configure
make

popd

PS_TAR=`ls -1td ?ercona-?erver* | grep ".tar" | head -n1`

if [ ! -z $PS_TAR ];then
  tar -xzf $PS_TAR
  PSBASE=`ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PSBASE/bin:$PATH"
fi
PSBASEDIR="${WORKDIR}/$PSBASE"
MID="${PSBASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PSBASEDIR}"
rm -rf ${PSBASEDIR}/data
${MID} --datadir=${PSBASEDIR}/data  > ${WORKDIR}/logs/startup.err 2>&1 || exit 1;

${PSBASEDIR}/bin/mysqld --no-defaults \
	--basedir=${PSBASEDIR} \
	--datadir=${PSBASEDIR}/data \
    --log-error=${WORKDIR}/logs/mysql.err \
    --socket=/tmp/mysql.sock \
	--log-output=none > ${WORKDIR}/logs/mysql.err 2>&1 &
	  
for X in $(seq 0 ${PS_START_TIMEOUT}); do
  sleep 1
  if ${PSBASEDIR}/bin/mysqladmin -uroot -S/tmp/mysql.sock ping > /dev/null 2>&1; then
    sleep 2
    ${PSBASEDIR}/bin/mysql -uroot -S/tmp/mysql.sock -e "create database sbtest" > /dev/null 2>&1
    break
  fi
done

pushd $SYSBENCH_SOURCE/tests
export SBTEST_MYSQL_ARGS="--mysql-host=localhost --mysql-user=root --mysql-socket=/tmp/mysql.sock --mysql-db=sbtest"
./test_run.sh
popd

