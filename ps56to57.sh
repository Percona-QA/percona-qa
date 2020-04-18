#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
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

sysbench_run(){
  SE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --mysql-table-engine=$SE --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --mysql_storage_engine=$SE --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --db-driver=mysql"
  fi
}

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

psdatadir="${MYSQL_VARDIR}/psdata"
mkdir -p $psdatadir

function create_emp_db()
{
  DB_NAME=$1
  SE_NAME=$2
  SQL_FILE=$3
  pushd $ROOT_FS/test_db
  cat $ROOT_FS/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > $ROOT_FS/test_db/${DB_NAME}_${SE_NAME}.sql
   $PS56_BASEDIR/bin/mysql --socket=${WORKDIR}/ps56.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

#Load jemalloc lib
if [ -r `find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
  export LD_PRELOAD=`find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
elif [ -r /sda/workdir/PS-mysql-5.7.10-1rc1-linux-x86_64-debug/lib/mysql/libjemalloc.so.1 ]; then
  export LD_PRELOAD=/sda/workdir/PS-mysql-5.7.10-1rc1-linux-x86_64-debug/lib/mysql/libjemalloc.so.1
else
  echoit "Error: jemalloc not found, please install it first"
  exit 1;
fi


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

#Install TokuDB plugin
echo "INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so'" | $PS56_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps56.sock
$PS56_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps56.sock < ${SCRIPT_PWD}/TokuDB.sql
echoit "Sysbench Run: Prepare stage"
sysbench_run innodb test
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps56.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

echoit "Loading sakila test database"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echoit "Loading world test database"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echoit "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql

echoit "Loading employees database with myisam engine.."
create_emp_db employee_3 myisam employees.sql

echoit "Loading employees partitioned database with myisam engine.."
create_emp_db employee_4 myisam employees_partitioned.sql

echoit "Drop foreign keys for changing storage engine"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root -Bse "SELECT CONCAT('ALTER TABlE ',TABLE_SCHEMA,'.',TABLE_NAME,' DROP FOREIGN KEY ',CONSTRAINT_NAME) as a FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE CONSTRAINT_TYPE='FOREIGN KEY' AND TABLE_SCHEMA NOT IN('mysql','information_schema','performance_schema','sys')" | while read drop_key ; do
  echoit "Executing : $drop_key"
  echo "$drop_key" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root
done

echoit "Altering tables to TokuDB.."

$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root -Bse "select concat('ALTER TABLE ',table_schema,'.',table_name,' ENGINE=TokuDB') as a from information_schema.tables where table_schema not in('mysql','information_schema','performance_schema','sys') and table_type='BASE TABLE'" | while read alter_tbl ; do
  echoit "Executing : $alter_tbl"
  echo "$alter_tbl" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
done

echoit "Sysbench Run: Creating MyISAM tables"
echo "CREATE DATABASE sysbench_myisam_db;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
sysbench_run myisam sysbench_myisam_db
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps56.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root sysbench_myisam_db -e"CREATE TABLE sbtest_mrg like sbtest1" || true

SBTABLE_LIST=`$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root -Bse "SELECT GROUP_CONCAT(table_name SEPARATOR ',') FROM information_schema.tables WHERE table_schema='sysbench_myisam_db' and table_name!='sbtest_mrg'"`

$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root sysbench_myisam_db -e"ALTER TABLE sbtest_mrg UNION=($SBTABLE_LIST), ENGINE=MRG_MYISAM" || true

echoit "Loading employees database with tokudb engine for upgrade testing.."
create_emp_db employee_5 tokudb employees.sql

echoit "Loading employees partitioned database with tokudb engine for upgrade testing.."
create_emp_db employee_6 tokudb employees_partitioned.sql

echoit "Loading employees database with innodb engine for upgrade testing.."
create_emp_db employee_7 innodb employees.sql

echoit "Loading employees partitioned database with innodb engine for upgrade testing.."
create_emp_db employee_8 innodb employees_partitioned.sql

echoit "Loading employees database with myisam engine for upgrade testing.."
create_emp_db employee_9 myisam employees.sql

echoit "Loading employees partitioned database with myisam engine for upgrade testing.."
create_emp_db employee_10 myisam employees_partitioned.sql

#Partition testing with sysbench data
echo "ALTER TABLE test.sbtest1 PARTITION BY HASH(id) PARTITIONS 8;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
echo "ALTER TABLE test.sbtest2 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
echo "ALTER TABLE test.sbtest3 PARTITION BY HASH(id) PARTITIONS 8;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
echo "ALTER TABLE test.sbtest4 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true

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

echo "ALTER TABLE test.sbtest1 COALESCE PARTITION 2;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true
echo "ALTER TABLE test.sbtest2 REORGANIZE PARTITION;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true
echo "ALTER TABLE test.sbtest3 ANALYZE PARTITION p1;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true
echo "ALTER TABLE test.sbtest4 CHECK PARTITION p2;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true

$PS57_BASEDIR/bin/mysql -S $WORKDIR/ps57.sock  -u root -e "show global variables like 'version';"

echoit "Downgrade testing with mysqlddump and reload.."
$PS57_BASEDIR/bin/mysqldump --set-gtid-purged=OFF  --triggers --routines --socket=$WORKDIR/ps57.sock -uroot --databases `$PS57_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"` > $WORKDIR/dbdump.sql 2>&1

psdatadir="${MYSQL_VARDIR}/ps56_down"
PORT1=$[50000 + ( $RANDOM % ( 9999 ) ) ]

pushd ${PS56_BASEDIR}/mysql-test/

set +e
perl mysql-test-run.pl \
  --start-and-exit \
  --vardir=$psdatadir \
  --mysqld=--port=$PORT1 \
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
  --mysqld=--log-error=$WORKDIR/logs/ps56_down.err \
  --mysqld=--socket=$WORKDIR/ps56_down.sock \
  --mysqld=--log-output=none \
1st
set -e
popd

${PS56_BASEDIR}/bin/mysql --socket=$WORKDIR/ps56_down.sock -uroot < $WORKDIR/dbdump.sql 2>&1

CHECK_DBS=`$PS57_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"`

echoit "Checking table status..."
${PS56_BASEDIR}/bin/mysqlcheck -uroot --socket=$WORKDIR/ps56_down.sock --check-upgrade --databases $CHECK_DBS 2>&1

${PS56_BASEDIR}/bin/mysqladmin -uroot --socket=$WORKDIR/ps56_down.sock shutdown
$PS57_BASEDIR/bin/mysqladmin  -S $WORKDIR/ps57.sock  -u root shutdown


function startup_check(){
  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${PS57_BASEDIR}/bin/mysqladmin -uroot -S$1 ping > /dev/null 2>&1; then
      break
    fi
  done
}
function rpl_test(){
  RPL_OPTION="$1"
  rm -rf ${MYSQL_VARDIR}/ps_master/
  ps_master_datadir="${MYSQL_VARDIR}/ps_master"
  PORT_MASTER=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  pushd ${PS56_BASEDIR}/mysql-test/

  set +e
  perl mysql-test-run.pl \
    --start-and-exit \
    --vardir=$ps_master_datadir \
    --mysqld=--port=$PORT_MASTER \
    --mysqld=--innodb_file_per_table \
    --mysqld=--default-storage-engine=InnoDB \
    --mysqld=--binlog-format=ROW \
    --mysqld=--innodb_flush_method=O_DIRECT \
    --mysqld=--core-file \
    --mysqld=--secure-file-priv= \
    --mysqld=--skip-name-resolve \
    --mysqld=--log-error=$WORKDIR/logs/ps_master.err \
    --mysqld=--socket=$WORKDIR/ps_master.sock \
    --mysqld=--log-output=none \
  1st
  set -e
  popd

  sleep 10

  $PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_master.sock -u root shutdown

  sleep 10
  rm -rf ${MYSQL_VARDIR}/ps_slave
  mkdir ${MYSQL_VARDIR}/ps_slave
  ps_slave_datadir="${MYSQL_VARDIR}/ps_slave"
  cp -a $ps_master_datadir/mysqld.1/data/* ${MYSQL_VARDIR}/ps_slave
  rm -rf ${MYSQL_VARDIR}/ps_slave/auto.cnf

  #Start master
  ${PS56_BASEDIR}/bin/mysqld --no-defaults   --basedir=${PS56_BASEDIR} --datadir=$ps_master_datadir/mysqld.1/data --port=$PORT_MASTER --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=101 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_master.err --socket=$WORKDIR/ps_master.sock --log-output=none > $WORKDIR/logs/ps_master.err 2>&1 &

  startup_check $WORKDIR/ps_master.sock
  #Start slave
  PORT_SLAVE=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  if [ "$RPL_OPTION" == "gtid" ]; then
    ${PS56_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS56_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &
  elif [ "$RPL_OPTION" == "mts" ]; then
    ${PS56_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS56_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --relay-log-info-repository='TABLE' --master-info-repository='TABLE' --slave-parallel-workers=2 --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &
  else
    ${PS56_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS56_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &
  fi

  startup_check $WORKDIR/ps_slave.sock

  if [ "$RPL_OPTION" == "gtid" -o "$RPL_OPTION" == "mts" ]; then
    echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='root',MASTER_AUTO_POSITION=1;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps_slave.sock -u root || true
  else
    echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='root',MASTER_LOG_FILE='mysql-bin.000001',MASTER_LOG_POS=4;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps_slave.sock -u root || true
  fi
  echo "START SLAVE;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps_slave.sock -u root || true

  echoit "Loading sakila test database"
  $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps_master.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

  #Check replication status
  SLAVE_IO_STATUS=`${PS56_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_IO_Running | awk '{ print $2 }'`
  SLAVE_SQL_STATUS=`${PS56_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_SQL_Running | awk '{ print $2 }'`

  if [ -z "$SLAVE_IO_STATUS" -o -z "$SLAVE_SQL_STATUS" ] ; then
    echoit "Error : Replication is not running, please check.."
    exit
  fi
  echoit "Replication status : Slave_IO_Running=$SLAVE_IO_STATUS - Slave_SQL_Running=$SLAVE_SQL_STATUS"

  #Upgrade PS 5.6 slave to 5.7 for replication test

  $PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_slave.sock -u root shutdown

  ${PS57_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS57_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none --skip-slave-start > $WORKDIR/logs/ps_slave.err 2>&1 &


  startup_check $WORKDIR/ps_slave.sock
  ${PS57_BASEDIR}/bin/mysql_upgrade --socket=$WORKDIR/ps_slave.sock -uroot > $WORKDIR/logs/ps_rpl_slave_upgrade.log 2>&1

  $PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_slave.sock -u root shutdown
  ${PS57_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS57_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &

  startup_check $WORKDIR/ps_slave.sock
  sysbench_run innodb test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps_master.sock prepare  2>&1 | tee $WORKDIR/logs/rpl_sysbench_prepare.txt

  #Upgrade PS 5.6 master

  $PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_master.sock -u root shutdown

  ${PS57_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS57_BASEDIR}  --datadir=$ps_master_datadir/mysqld.1/data  --port=$PORT_MASTER --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_master.err --socket=$WORKDIR/ps_master.sock --log-output=none > $WORKDIR/logs/ps_master.err 2>&1 &

  startup_check $WORKDIR/ps_master.sock
  ${PS57_BASEDIR}/bin/mysql_upgrade --socket=$WORKDIR/ps_master.sock -uroot > $WORKDIR/logs/ps_rpl_master_upgrade.log 2>&1

  $PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_master.sock -u root shutdown

  ${PS57_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS57_BASEDIR}  --datadir=$ps_master_datadir/mysqld.1/data  --port=$PORT_MASTER --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=101 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_master.err --socket=$WORKDIR/ps_master.sock --log-output=none > $WORKDIR/logs/ps_master.err 2>&1 &

  startup_check $WORKDIR/ps_master.sock

  #Check replication status
  SLAVE_IO_STATUS=`${PS56_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_IO_Running | awk '{ print $2 }'`
  SLAVE_SQL_STATUS=`${PS56_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_SQL_Running | awk '{ print $2 }'`

  if [ -z "$SLAVE_IO_STATUS" -o -z "$SLAVE_SQL_STATUS" ] ; then
    echoit "Error : Replication is not running, please check.."
    exit
  fi

  echoit "Replication status after master upgrade : Slave_IO_Running=$SLAVE_IO_STATUS - Slave_SQL_Running=$SLAVE_SQL_STATUS"
  ${PS57_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_master.sock shutdown
  ${PS57_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_slave.sock shutdown
}
rpl_test
rpl_test gtid
rpl_test mts

