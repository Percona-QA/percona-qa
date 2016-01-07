#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
LPATH="/usr/share/doc/sysbench/tests/db"

if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

if [ -z ${SDURATION} ]; then
  SDURATION=100
fi

if [ -z ${TSIZE} ]; then
  TSIZE=500
fi

if [ -z ${NUMT} ]; then
  NUMT=16
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=10
fi

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

cd $WORKDIR

PS56_TAR=`ls -1td ?ercona-?erver-5.6* | grep ".tar" | head -n1`
PS57_TAR=`ls -1td ?ercona-?erver-5.7* | grep ".tar" | head -n1`

if [ ! -z $PS56_TAR ];then
  tar -xzf $PS56_TAR
  PS56_BASE=`ls -1td ?ercona-?erver-5.6* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PS56_BASE/bin:$PATH"
fi

if [ ! -z $PS57_TAR ];then
  tar -xzf $PS57_TAR
  PS57_BASE=`ls -1td ?ercona-?erver-5.7* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PS57_BASE/bin:$PATH"
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
PS56_BASEDIR="${ROOT_FS}/$PS56_BASE"
PS57_BASEDIR="${ROOT_FS}/$PS57_BASE"

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR
mkdir -p $WORKDIR/logs

psdatadir="${MYSQL_VARDIR}/ps56"
mkdir -p $psdatadir

pushd ${PS56_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
  --start-and-exit \
  --vardir=$psdatadir \
  --mysqld=--port=$PORT \
  --mysqld=--innodb_file_per_table \
  --mysqld=--default-storage-engine=InnoDB \
  --mysqld=--binlog-format=ROW \
  --mysqld=--log-bin=mysql-bin \
  --mysqld=--server-id=101 \
  --mysqld=--gtid-mode=ON  \
  --mysqld=--log-slave-updates \
  --mysqld=--enforce-gtid-consistency \
  --mysqld=--innodb_flush_method=O_DIRECT \
  --mysqld=--core-file \
  --mysqld=--secure-file-priv= \
  --mysqld=--skip-name-resolve \
  --mysqld=--log-error=$WORKDIR/logs/ps56.err \
  --mysqld=--socket=$WORKDIR/ps56.sock \
  --mysqld=--log-output=none \
1st  
set -e
popd

echo "Sysbench Run: Prepare stage"

$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=$WORKDIR/ps56.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

echo "Load Sakila db"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echo "Load world db"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql
 
$PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps56.sock -u root shutdown


pushd ${PS57_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
  --start-and-exit \
  --start-dirty \
  --vardir=$psdatadir \
  --mysqld=--port=$PORT \
  --mysqld=--innodb_file_per_table \
  --mysqld=--default-storage-engine=InnoDB \
  --mysqld=--binlog-format=ROW \
  --mysqld=--log-bin=mysql-bin \
  --mysqld=--server-id=101 \
  --mysqld=--gtid-mode=ON  \
  --mysqld=--log-slave-updates \
  --mysqld=--enforce-gtid-consistency \
  --mysqld=--innodb_flush_method=O_DIRECT \
  --mysqld=--core-file \
  --mysqld=--secure-file-priv= \
  --mysqld=--skip-name-resolve \
  --mysqld=--log-error=$WORKDIR/logs/ps57.err \
  --mysqld=--socket=$WORKDIR/ps57.sock \
  --mysqld=--log-output=none \
1st  
set -e
popd

$PS57_BASEDIR/bin/mysql_upgrade -S $WORKDIR/ps57.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

$PS57_BASEDIR/bin/mysql -S $WORKDIR/ps57.sock  -u root -e "show global variables like 'version';"

