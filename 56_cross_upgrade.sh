#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
LPATH="/usr/share/doc/sysbench/tests/db"
MYSQLD_START_TIMEOUT=200

if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"

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

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/upgrade_testing.log; fi
}

trap cleanup EXIT KILL

cd $ROOT_FS

if [ ! -d $ROOT_FS/test_db ]; then
  git clone https://github.com/datacharmer/test_db.git
fi

MS56_TAR=`ls -1td mysql-5.6* | grep ".tar" | head -n1` || true
PS57_TAR=`ls -1td ?ercona-?erver-5.7* | grep ".tar" | head -n1` || true
MS57_TAR=`ls -1td mysql-5.7.11* | grep ".tar" | head -n1` ||  true

if [ ! -z $MS56_TAR ];then
  tar -xzf $MS56_TAR
  MS56_BASE=`ls -1td mysql-5.6* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$MS56_BASE/bin:$PATH"
else
  wget http://dev.mysql.com/get/Downloads/MySQL-5.6/mysql-5.6.29-linux-glibc2.5-x86_64.tar.gz
  MS56_TAR=`ls -1td mysql-5.6* | grep ".tar" | head -n1`
  tar -xzf $MS56_TAR
  MS56_BASE=`ls -1td mysql-5.6* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$MS56_BASE/bin:$PATH"
fi

if [ ! -z $PS57_TAR ];then
  tar -xzf $PS57_TAR
  PS57_BASE=`ls -1td ?ercona-?erver-5.7* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PS57_BASE/bin:$PATH"
fi

if [ ! -z $MS57_TAR ];then
  tar -xzf $MS57_TAR
  MS57_BASE=`ls -1td mysql-5.7.11* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$MS57_BASE/bin:$PATH"
else
  wget http://dev.mysql.com/get/Downloads/MySQL-5.7/mysql-test-5.7.11-linux-glibc2.5-x86_64.tar.gz
  wget http://dev.mysql.com/get/Downloads/MySQL-5.7/mysql-5.7.11-linux-glibc2.5-x86_64.tar.gz
  MS_TEST_TAR=`ls -1td mysql-test-5.7.11* | grep -v ".tar" | head -n1`
  MS57_TAR=`ls -1td mysql-5.7.11* | grep ".tar" | head -n1`
  tar -xzf $MS57_TAR
  tar -xzf $MS_TEST_TAR
  MS57_BASE=`ls -1td mysql-5.7* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$MS57_BASE/bin:$PATH"
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
MS56_BASEDIR="${ROOT_FS}/$MS56_BASE"
PS57_BASEDIR="${ROOT_FS}/$PS57_BASE"
MS57_BASEDIR="${ROOT_FS}/$MS57_BASE"

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR
mkdir -p $WORKDIR/logs

psdatadir="${MYSQL_VARDIR}/psdata"
mkdir -p $psdatadir

function create_emp_db()
{
  DB_NAME=$1
  SE_NAME=$2
  SQL_FILE=$3
  SOCKET=$4
  pushd $ROOT_FS/test_db
  cat $ROOT_FS/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > $ROOT_FS/test_db/${DB_NAME}_${SE_NAME}.sql
   $MS56_BASEDIR/bin/mysql --socket=$SOCKET -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

pushd ${MS56_BASEDIR}/mysql-test/

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
  --mysqld=--log-error=$WORKDIR/logs/ms56.err \
  --mysqld=--socket=$WORKDIR/ms56.sock \
  --mysqld=--log-output=none \
1st
set -e
popd

echoit "Sysbench Run: Prepare stage"

$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=$WORKDIR/ms56.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

echoit "Loading sakila test database"
$MS56_BASEDIR/bin/mysql --socket=$WORKDIR/ms56.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echoit "Loading world test database"
$MS56_BASEDIR/bin/mysql --socket=$WORKDIR/ms56.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echoit "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql $WORKDIR/ms56.sock

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql $WORKDIR/ms56.sock

echoit "Loading employees database with myisam engine.."
create_emp_db employee_3 myisam employees.sql $WORKDIR/ms56.sock

echoit "Version info before cross upgrade (MS-5.6>PS-5.7)"
$MS56_BASEDIR/bin/mysql -S $WORKDIR/ms56.sock  -u root -e "select @@version,@@version_comment;"

$MS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ms56.sock -u root shutdown

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

$PS57_BASEDIR/bin/mysql_upgrade -S $WORKDIR/ps57.sock -u root 2>&1 | tee $WORKDIR/logs/ps_mysql_upgrade.log

echoit "Loading sakila test database"
$MS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echoit "Loading world test database"
$MS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echoit "Loading employees database with innodb engine.."
create_emp_db employee_4 innodb employees.sql $WORKDIR/ps57.sock

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_5 innodb employees_partitioned.sql $WORKDIR/ps57.sock

echoit "Loading employees database with myisam engine.."
create_emp_db employee_6 myisam employees.sql $WORKDIR/ps57.sock

if grep -qi "ERROR" $WORKDIR/logs/ps57.err; then
  echoit "Alert! Please check the error log.."
fi

echoit "Version info after cross upgrade (MS-5.6>PS-5.7)"
$PS57_BASEDIR/bin/mysql -S $WORKDIR/ps57.sock  -u root -e "select @@version,@@version_comment;"

$PS57_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps57.sock -u root shutdown

PORT1=$[50000 + ( $RANDOM % ( 9999 ) ) ]

pushd ${MS57_BASEDIR}/mysql-test/

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
  --mysqld=--log-error=$WORKDIR/logs/ms57.err \
  --mysqld=--socket=$WORKDIR/ms57.sock \
  --mysqld=--log-output=none \
1st
set -e
popd

$MS57_BASEDIR/bin/mysql_upgrade -S $WORKDIR/ms57.sock -u root --force 2>&1 | tee $WORKDIR/logs/ms_mysql_upgrade.log

echoit "Loading sakila test database"
$MS57_BASEDIR/bin/mysql --socket=$WORKDIR/ms57.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echoit "Loading world test database"
$MS57_BASEDIR/bin/mysql --socket=$WORKDIR/ms57.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echoit "Loading employees database with innodb engine.."
create_emp_db employee_7 innodb employees.sql $WORKDIR/ms57.sock

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_8 innodb employees_partitioned.sql $WORKDIR/ms57.sock

echoit "Loading employees database with myisam engine.."
create_emp_db employee_9 myisam employees.sql $WORKDIR/ms57.sock

if grep -qi "ERROR" $WORKDIR/logs/ms57.err; then
  echoit "Alert! Please check the error log.."
fi

echoit "Version info after cross upgrade (PS-5.7>MS-5.7)"
$MS57_BASEDIR/bin/mysql -S $WORKDIR/ms57.sock  -u root -e "select @@version,@@version_comment;"

$MS57_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ms57.sock -u root shutdown

