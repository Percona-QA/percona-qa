#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test PS upgrade
# Usage example:
# $ ~/percona-qa/ps_upgrade.sh <workdir> <lower_basedir> <upper_basedir>"
# $ ~/percona-qa/ps_upgrade.sh /qa/workdir percona-server-5.7.22-22-linux-x86_64-debug percona-server-8.0.12-1-linux-x86_64-debug"

# Bash internal configuration
#
set -o nounset    # no undefined variables

# Global variables
declare SBENCH="sysbench"
declare PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
declare WORKDIR=$1
declare PS_LOWER_BASE=$2
declare PS_UPPER_BASE=$3
declare ROOT_FS=$WORKDIR
declare SCRIPT_PWD=$(cd `dirname $0` && pwd)
declare MYSQLD_START_TIMEOUT=200
declare BUILD_NUMBER=""
declare SDURATION=""
declare TSIZE=""
declare NUMT=""
declare TCOUNT=""
declare SYSBENCH_OPTIONS=""
declare PS_UPPER_BASEDIR=""
declare PS_UPPER_BASEDIR=""
declare LOWER_MID
declare UPPER_MID
declare PS_START_TIMEOUT=60

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER=1001
fi

if [ -z $ROOT_FS ]; then
  ROOT_FS=${PWD}
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

#Format version string (thanks to wsrep_sst_xtrabackup-v2) 
normalize_version(){
  local major=0
  local minor=0
  local patch=0
  
  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  fi
  printf %02d%02d%02d $major $minor $patch
}

#Version comparison script (thanks to wsrep_sst_xtrabackup-v2) 
check_for_version()
{
  local local_version_str="$( normalize_version $1 )"
  local required_version_str="$( normalize_version $2 )"
  
  if [[ "$local_version_str" < "$required_version_str" ]]; then
    return 1
  else
    return 0
  fi
}

sysbench_run(){
  local SE="$1"
  local DB="$2"
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

PS_LOWER_TAR=`readlink -e ${PS_LOWER_BASE}* | grep ".tar" | head -n1`
PS_UPPER_TAR=`readlink -e ${PS_UPPER_BASE}* | grep ".tar" | head -n1`

if [ ! -z $PS_LOWER_TAR ];then
  tar -xzf $PS_LOWER_TAR
  PS_LOWER_BASEDIR=`readlink -e ${PS_LOWER_BASE}* | grep -v ".tar" | head -n1`
  export PATH="$PS_LOWER_BASEDIR/bin:$PATH"
else
  PS_LOWER_BASEDIR=`readlink -e ${PS_LOWER_BASE}* | grep -v ".tar" | head -n1`
  if [ ! -z $PS_LOWER_BASEDIR ]; then
    export PATH="$PS_LOWER_BASEDIR/bin:$PATH"
  else
    echoit "ERROR! Could not find $PS_LOWER_BASE binary"
    exit 1
  fi
fi

if [ ! -z $PS_UPPER_TAR ];then
  tar -xzf $PS_UPPER_TAR
  PS_UPPER_BASEDIR=`readlink -e ${PS_UPPER_BASE}* | grep -v ".tar" | head -n1`
  export PATH="$PS_UPPER_BASEDIR/bin:$PATH"
else
  PS_UPPER_BASEDIR=`readlink -e ${PS_UPPER_BASE}* | grep -v ".tar" | head -n1`
  if [ ! -z $PS_UPPER_BASEDIR ]; then
    export PATH="$PS_UPPER_BASEDIR/bin:$PATH"
  else
    echoit "ERROR! Could not find $PS_UPPER_BASE binary"
    exit 1
  fi
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR
mkdir -p $WORKDIR/logs

psdatadir="${MYSQL_VARDIR}/psdata"
mkdir -p $psdatadir

function create_emp_db()
{
  local DB_NAME=$1
  local SE_NAME=$2
  local SQL_FILE=$3
  pushd $ROOT_FS/test_db
  cat $ROOT_FS/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > $ROOT_FS/test_db/${DB_NAME}_${SE_NAME}.sql
   $PS_LOWER_BASEDIR/bin/mysql --socket=${WORKDIR}/ps_lower.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

#Load jemalloc lib
if [ -r `find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
  export LD_PRELOAD=`find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
elif [ -r $PS_UPPER_BASEDIR/lib/mysql/libjemalloc.so.1 ]; then
  export LD_PRELOAD=$PS_UPPER_BASEDIR/lib/mysql/libjemalloc.so.1
else
  echoit "Error: jemalloc not found, please install it first"
  exit 1;
fi


declare MYSQL_VERSION=$(${PS_LOWER_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  LOWER_MID="${PS_LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PS_LOWER_BASEDIR}"
else
  LOWER_MID="${PS_LOWER_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PS_LOWER_BASEDIR}"
fi

declare MYSQL_VERSION=$(${PS_UPPER_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  UPPER_MID="${PS_UPPER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PS_UPPER_BASEDIR}"
else
  UPPER_MID="${PS_UPPER_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PS_UPPER_BASEDIR}"
fi


echo "[mysqld]" > ${WORKDIR}/ps_lower.cnf
echo "basedir=${PS_LOWER_BASEDIR}" >> $WORKDIR/ps_lower.cnf
echo "datadir=$psdatadir" >> $WORKDIR/ps_lower.cnf
echo "port=$PORT" >> $WORKDIR/ps_lower.cnf
echo "innodb_file_per_table" >> $WORKDIR/ps_lower.cnf
echo "default-storage-engine=InnoDB" >> $WORKDIR/ps_lower.cnf
echo "binlog-format=ROW" >> $WORKDIR/ps_lower.cnf
echo "log-bin=mysql-bin" >> $WORKDIR/ps_lower.cnf
echo "server-id=101" >> $WORKDIR/ps_lower.cnf
echo "gtid-mode=ON " >> $WORKDIR/ps_lower.cnf
echo "log-slave-updates" >> $WORKDIR/ps_lower.cnf
echo "enforce-gtid-consistency" >> $WORKDIR/ps_lower.cnf
echo "innodb_flush_method=O_DIRECT" >> $WORKDIR/ps_lower.cnf
echo "core-file" >> $WORKDIR/ps_lower.cnf
echo "secure-file-priv=" >> $WORKDIR/ps_lower.cnf
echo "skip-name-resolve" >> $WORKDIR/ps_lower.cnf
echo "log-error=$WORKDIR/logs/ps_lower.err" >> $WORKDIR/ps_lower.cnf
echo "socket=$WORKDIR/ps_lower.sock" >> $WORKDIR/ps_lower.cnf
echo "log-output=none" >> $WORKDIR/ps_lower.cnf


${LOWER_MID} --datadir=$psdatadir  > $WORKDIR/logs/ps_lower.err 2>&1 || exit 1;
${PS_LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/ps_lower.cnf > $WORKDIR/logs/ps_lower.err 2>&1 &

for X in $(seq 0 ${PS_START_TIMEOUT}); do
  sleep 1
  if ${PS_LOWER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_lower.sock ping > /dev/null 2>&1; then
    ${PS_LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/ps_lower.sock -e"drop database if exists test; create database test"
    break
  fi
  if [ $X -eq ${PS_START_TIMEOUT} ]; then
    echoit "PS startup failed.."
    grep "ERROR" $WORKDIR/logs/ps_lower.err
    exit 1
    fi
done
	  
echoit "Sysbench Run: Prepare stage"
sysbench_run innodb test
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps_lower.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

echoit "Loading sakila test database"
$PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echoit "Loading world test database"
$PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echoit "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql

echoit "Loading employees database with myisam engine.."
create_emp_db employee_3 myisam employees.sql

if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
  echoit "Loading employees partitioned database with myisam engine.."
  create_emp_db employee_4 myisam employees_partitioned.sql
fi

echoit "Sysbench Run: Creating MyISAM tables"
echo "CREATE DATABASE sysbench_myisam_db;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root || true
sysbench_run myisam sysbench_myisam_db
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps_lower.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

$PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root sysbench_myisam_db -e"CREATE TABLE sbtest_mrg like sbtest1" || true

SBTABLE_LIST=`$PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root -Bse "SELECT GROUP_CONCAT(table_name SEPARATOR ',') FROM information_schema.tables WHERE table_schema='sysbench_myisam_db' and table_name!='sbtest_mrg'"`

$PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root sysbench_myisam_db -e"ALTER TABLE sbtest_mrg UNION=($SBTABLE_LIST), ENGINE=MRG_MYISAM" || true

if [ -r ${PS_LOWER_BASEDIR}/lib/mysql/plugin/ha_tokudb.so ]; then
  #Install TokuDB plugin
  echo "INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so'" | $PS_LOWER_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps_lower.sock
  $PS_LOWER_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps_lower.sock < ${SCRIPT_PWD}/TokuDB.sql

  echoit "Loading employees database with tokudb engine for upgrade testing.."
  create_emp_db employee_5 tokudb employees.sql
  
  if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
    echoit "Loading employees partitioned database with tokudb engine for upgrade testing.."
    create_emp_db employee_6 tokudb employees_partitioned.sql
  fi
fi

if [ -r ${PS_LOWER_BASEDIR}/lib/mysql/plugin/ha_rocksdb.so ]; then
  #Install RocksDB plugin
  echo "INSTALL PLUGIN rocksdb SONAME 'ha_rocksdb.so'" | $PS_LOWER_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps_lower.sock
  $PS_LOWER_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps_lower.sock < ${SCRIPT_PWD}/MyRocks.sql

  echo "DROP DATABASE IF EXISTS rocksdb_test;CREATE DATABASE IF NOT EXISTS rocksdb_test; set global default_storage_engine = ROCKSDB " | $PS_LOWER_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps_lower.sock

  echoit "Sysbench rocksdb data load"
  sysbench_run rocksdb rocksdb_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps_lower.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_rocksdb_prepare.txt

  if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
    echoit "Creating rocksdb partitioned tables"
    for i in `seq 1 10`; do
      ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "create table rocksdb_test.tbl_range${i} (id int auto_increment,str varchar(32),year_col int, primary key(id,year_col)) PARTITION BY RANGE (year_col) ( PARTITION p0 VALUES LESS THAN (1991), PARTITION p1 VALUES LESS THAN (1995),PARTITION p2 VALUES LESS THAN (2000))" 2>&1
      ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "CREATE TABLE rocksdb_test.tbl_list${i} (c1 INT, c2 INT ) PARTITION BY LIST(c1) ( PARTITION p0 VALUES IN (1, 3, 5, 7, 9),PARTITION p1 VALUES IN (2, 4, 6, 8) );" 2>&1
      ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "CREATE TABLE rocksdb_test.tbl_key${i} ( id INT NOT NULL PRIMARY KEY auto_increment, str_value VARCHAR(100)) PARTITION BY KEY() PARTITIONS 5;" 2>&1
      ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "CREATE TABLE rocksdb_test.tbl_sub_part${i} (id int, purchased DATE) PARTITION BY RANGE( YEAR(purchased) ) SUBPARTITION BY HASH( TO_DAYS(purchased) ) SUBPARTITIONS 2 ( PARTITION p0 VALUES LESS THAN (1990),PARTITION p1 VALUES LESS THAN (2000),PARTITION p2 VALUES LESS THAN MAXVALUE);" 2>&1
    done
    ARR_YEAR=( 1985 1986 1987 1988 1989 1990 1991 1992 1993 1994 1995 1996 1997 1998 1999 )
    ARR_L1=( 1 3 5 7 9 )
    ARR_L2=( 2 4 6 8 )
    ARR_DATE=( 1988-09-20 1989-10-14 1990-08-24 1993-05-12 1995-02-17 2000-03-04 2001-08-23 2007-02-24 2017-04-01 )
    for i in `seq 1 1000`; do
      for j in `seq 1 10`; do
        rand_year=$[$RANDOM % 15]
        rand_list1=$[$RANDOM % 5]
        rand_list2=$[$RANDOM % 4]
        rand_sub=$[$RANDOM % 9]
        STRING=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
        ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "INSERT INTO rocksdb_test.tbl_range${j} (str,year_col) VALUES ('${STRING}',${ARR_YEAR[$rand_year]})"
        ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "INSERT INTO rocksdb_test.tbl_list${j} VALUES (${ARR_L1[$rand_list1]},${ARR_L2[$rand_list2]})"
        ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "INSERT INTO rocksdb_test.tbl_key${j} (str_value) VALUES ('${STRING}')"
        ${PS_LOWER_BASEDIR}/bin/mysql -uroot --socket=$WORKDIR/ps_lower.sock -e "INSERT INTO rocksdb_test.tbl_sub_part${j} VALUES (${i},'${ARR_DATE[$rand_sub]}')"
      done
    done
  fi
fi

#Partition testing with sysbench data
echo "ALTER TABLE test.sbtest1 PARTITION BY HASH(id) PARTITIONS 8;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root || true
echo "ALTER TABLE test.sbtest2 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root || true
echo "ALTER TABLE test.sbtest3 PARTITION BY HASH(id) PARTITIONS 8;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root || true
echo "ALTER TABLE test.sbtest4 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_lower.sock -u root || true

$PS_LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_lower.sock -u root shutdown

echo "[mysqld]" > ${WORKDIR}/ps_upper.cnf
echo "basedir=${PS_UPPER_BASEDIR}" >> $WORKDIR/ps_upper.cnf
echo "datadir=$psdatadir" >> $WORKDIR/ps_upper.cnf
echo "port=$PORT" >> $WORKDIR/ps_upper.cnf
echo "innodb_file_per_table" >> $WORKDIR/ps_upper.cnf
echo "default-storage-engine=InnoDB" >> $WORKDIR/ps_upper.cnf
echo "binlog-format=ROW" >> $WORKDIR/ps_upper.cnf
echo "log-bin=mysql-bin" >> $WORKDIR/ps_upper.cnf
echo "server-id=101" >> $WORKDIR/ps_upper.cnf
echo "gtid-mode=ON " >> $WORKDIR/ps_upper.cnf
echo "log-slave-updates" >> $WORKDIR/ps_upper.cnf
echo "enforce-gtid-consistency" >> $WORKDIR/ps_upper.cnf
echo "innodb_flush_method=O_DIRECT" >> $WORKDIR/ps_upper.cnf
echo "core-file" >> $WORKDIR/ps_upper.cnf
echo "secure-file-priv=" >> $WORKDIR/ps_upper.cnf
echo "skip-name-resolve" >> $WORKDIR/ps_upper.cnf
echo "log-error=$WORKDIR/logs/ps_upper.err" >> $WORKDIR/ps_upper.cnf
echo "socket=$WORKDIR/ps_upper.sock" >> $WORKDIR/ps_upper.cnf
echo "log-output=none" >> $WORKDIR/ps_upper.cnf

${PS_UPPER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/ps_upper.cnf > $WORKDIR/logs/ps_upper.err 2>&1 &

for X in $(seq 0 ${PS_START_TIMEOUT}); do
  sleep 1
  if ${PS_UPPER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_upper.sock ping > /dev/null 2>&1; then
    break
  fi
  if [ $X -eq ${PS_START_TIMEOUT} ]; then
    echoit "PS startup failed.."
    grep "ERROR" $WORKDIR/logs/ps_upper.err
    exit 1
    fi
done

$PS_UPPER_BASEDIR/bin/mysql_upgrade -S $WORKDIR/ps_upper.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

echo "ALTER TABLE test.sbtest1 COALESCE PARTITION 2;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_upper.sock -u root || true
echo "ALTER TABLE test.sbtest2 REORGANIZE PARTITION;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_upper.sock -u root || true
echo "ALTER TABLE test.sbtest3 ANALYZE PARTITION p1;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_upper.sock -u root || true
echo "ALTER TABLE test.sbtest4 CHECK PARTITION p2;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_upper.sock -u root || true

$PS_UPPER_BASEDIR/bin/mysql -S $WORKDIR/ps_upper.sock  -u root -e "show global variables like 'version';"

echoit "Downgrade testing with mysqlddump and reload.."
$PS_UPPER_BASEDIR/bin/mysqldump --set-gtid-purged=OFF  --triggers --routines --socket=$WORKDIR/ps_upper.sock -uroot --databases `$PS_UPPER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_upper.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"` > $WORKDIR/dbdump.sql 2>&1

psdatadir="${MYSQL_VARDIR}/ps_lower_down"
PORT1=$[50000 + ( $RANDOM % ( 9999 ) ) ]

echo "[mysqld]" > ${WORKDIR}/ps_lower_down.cnf
echo "basedir=${PS_LOWER_BASEDIR}" >> $WORKDIR/ps_lower_down.cnf
echo "datadir=$psdatadir" >> $WORKDIR/ps_lower_down.cnf
echo "port=$PORT1" >> $WORKDIR/ps_lower_down.cnf
echo "innodb_file_per_table" >> $WORKDIR/ps_lower_down.cnf
echo "default-storage-engine=InnoDB" >> $WORKDIR/ps_lower_down.cnf
echo "binlog-format=ROW" >> $WORKDIR/ps_lower_down.cnf
echo "log-bin=mysql-bin" >> $WORKDIR/ps_lower_down.cnf
echo "server-id=101" >> $WORKDIR/ps_lower_down.cnf
echo "gtid-mode=ON " >> $WORKDIR/ps_lower_down.cnf
echo "log-slave-updates" >> $WORKDIR/ps_lower_down.cnf
echo "enforce-gtid-consistency" >> $WORKDIR/ps_lower_down.cnf
echo "innodb_flush_method=O_DIRECT" >> $WORKDIR/ps_lower_down.cnf
echo "core-file" >> $WORKDIR/ps_lower_down.cnf
echo "secure-file-priv=" >> $WORKDIR/ps_lower_down.cnf
echo "skip-name-resolve" >> $WORKDIR/ps_lower_down.cnf
echo "log-error=$WORKDIR/logs/ps_lower_down.err" >> $WORKDIR/ps_lower_down.cnf
echo "socket=$WORKDIR/ps_lower_down.sock" >> $WORKDIR/ps_lower_down.cnf
echo "log-output=none" >> $WORKDIR/ps_lower_down.cnf

${LOWER_MID} --datadir=$psdatadir  > $WORKDIR/logs/ps_lower_down.err 2>&1 || exit 1;
${PS_LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/ps_lower_down.cnf > $WORKDIR/logs/ps_lower_down.err 2>&1 &

for X in $(seq 0 ${PS_START_TIMEOUT}); do
  sleep 1
  if ${PS_LOWER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_lower_down.sock ping > /dev/null 2>&1; then
    ${PS_LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/ps_lower_down.sock -e"drop database if exists test; create database test"
    break
  fi
  if [ $X -eq ${PS_START_TIMEOUT} ]; then
    echoit "PS startup failed.."
    grep "ERROR" $WORKDIR/logs/ps_lower_down.err
    exit 1
    fi
done

${PS_LOWER_BASEDIR}/bin/mysql --socket=$WORKDIR/ps_lower_down.sock -uroot < $WORKDIR/dbdump.sql 2>&1

CHECK_DBS=`$PS_UPPER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_upper.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"`

echoit "Checking table status..."
${PS_LOWER_BASEDIR}/bin/mysqlcheck -uroot --socket=$WORKDIR/ps_lower_down.sock --check-upgrade --databases $CHECK_DBS 2>&1

${PS_LOWER_BASEDIR}/bin/mysqladmin -uroot --socket=$WORKDIR/ps_lower_down.sock shutdown
${PS_UPPER_BASEDIR}/bin/mysqladmin  -S $WORKDIR/ps_upper.sock  -u root shutdown


function startup_check(){
  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${PS_UPPER_BASEDIR}/bin/mysqladmin -uroot -S$1 ping > /dev/null 2>&1; then
      break
    fi
  done
}
function rpl_test(){
  RPL_OPTION="${1:-}"
  rm -rf ${MYSQL_VARDIR}/ps_master/
  ps_master_datadir="${MYSQL_VARDIR}/ps_master"
  PORT_MASTER=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  echo "[mysqld]" > ${WORKDIR}/ps_master.cnf
  echo "basedir=${PS_LOWER_BASEDIR}" >> $WORKDIR/ps_master.cnf
  echo "datadir=$ps_master_datadir" >> $WORKDIR/ps_master.cnf
  echo "port=$PORT_MASTER" >> $WORKDIR/ps_master.cnf
  echo "innodb_file_per_table" >> $WORKDIR/ps_master.cnf
  echo "default-storage-engine=InnoDB" >> $WORKDIR/ps_master.cnf
  echo "binlog-format=ROW" >> $WORKDIR/ps_master.cnf
  echo "innodb_flush_method=O_DIRECT" >> $WORKDIR/ps_master.cnf
  echo "core-file" >> $WORKDIR/ps_master.cnf
  echo "secure-file-priv=" >> $WORKDIR/ps_master.cnf
  echo "skip-name-resolve" >> $WORKDIR/ps_master.cnf
  echo "log-error=$WORKDIR/logs/ps_master.err" >> $WORKDIR/ps_master.cnf
  echo "socket=$WORKDIR/ps_master.sock" >> $WORKDIR/ps_master.cnf
  echo "log-output=none" >> $WORKDIR/ps_master.cnf

  ${LOWER_MID} --datadir=$ps_master_datadir  > $WORKDIR/logs/ps_master.err 2>&1 || exit 1;
  ${PS_LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/ps_master.cnf > $WORKDIR/logs/ps_master.err 2>&1 &

  for X in $(seq 0 ${PS_START_TIMEOUT}); do
    sleep 1
    if ${PS_LOWER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_master.sock ping > /dev/null 2>&1; then
      ${PS_LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/ps_master.sock -e"drop database if exists test; create database test"
      break
    fi
    if [ $X -eq ${PS_START_TIMEOUT} ]; then
      echoit "PS Master startup failed.."
      grep "ERROR" $WORKDIR/logs/ps_master.err
      exit 1
      fi
  done

  $PS_LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_master.sock -u root shutdown

  sleep 10
  rm -rf ${MYSQL_VARDIR}/ps_slave
  mkdir ${MYSQL_VARDIR}/ps_slave
  ps_slave_datadir="${MYSQL_VARDIR}/ps_slave"
  cp -r $ps_master_datadir/* ${MYSQL_VARDIR}/ps_slave
  rm -rf ${MYSQL_VARDIR}/ps_slave/auto.cnf

  #Start master
  ${PS_LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/ps_master.cnf > $WORKDIR/logs/ps_master.err 2>&1 &

  startup_check $WORKDIR/ps_master.sock
  #Start slave
  PORT_SLAVE=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  if [ "$RPL_OPTION" == "gtid" ]; then
    ${PS_LOWER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_LOWER_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &
  elif [ "$RPL_OPTION" == "mts" ]; then
    ${PS_LOWER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_LOWER_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --relay-log-info-repository='TABLE' --master-info-repository='TABLE' --slave-parallel-workers=2 --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &
  else
    ${PS_LOWER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_LOWER_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &
  fi

  startup_check $WORKDIR/ps_slave.sock

  if [ "$RPL_OPTION" == "gtid" -o "$RPL_OPTION" == "mts" ]; then
    echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='root',MASTER_AUTO_POSITION=1;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_slave.sock -u root || true
  else
    echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='root',MASTER_LOG_FILE='mysql-bin.000001',MASTER_LOG_POS=4;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_slave.sock -u root || true
  fi
  echo "START SLAVE;" | $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_slave.sock -u root || true

  echoit "Loading sakila test database"
  $PS_LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/ps_master.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

  #Check replication status
  SLAVE_IO_STATUS=`${PS_LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_IO_Running | awk '{ print $2 }'`
  SLAVE_SQL_STATUS=`${PS_LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_SQL_Running | awk '{ print $2 }'`

  if [ -z "$SLAVE_IO_STATUS" -o -z "$SLAVE_SQL_STATUS" ] ; then
    echoit "Error : Replication is not running, please check.."
    exit
  fi
  echoit "Replication status : Slave_IO_Running=$SLAVE_IO_STATUS - Slave_SQL_Running=$SLAVE_SQL_STATUS"

  #Upgrade PS $PS_LOWER_VERSION slave to $PS_UPPER_VERSION for replication test

  $PS_LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_slave.sock -u root shutdown

  ${PS_UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_UPPER_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none --skip-slave-start > $WORKDIR/logs/ps_slave.err 2>&1 &


  startup_check $WORKDIR/ps_slave.sock
  ${PS_UPPER_BASEDIR}/bin/mysql_upgrade --socket=$WORKDIR/ps_slave.sock -uroot > $WORKDIR/logs/ps_rpl_slave_upgrade.log 2>&1

  $PS_LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_slave.sock -u root shutdown
  ${PS_UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_UPPER_BASEDIR}  --datadir=$ps_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_slave.err --socket=$WORKDIR/ps_slave.sock --log-output=none > $WORKDIR/logs/ps_slave.err 2>&1 &

  startup_check $WORKDIR/ps_slave.sock
  sysbench_run innodb test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/ps_master.sock prepare  2>&1 | tee $WORKDIR/logs/rpl_sysbench_prepare.txt

  #Upgrade PS $PS_LOWER_VERSION master

  $PS_LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_master.sock -u root shutdown

  ${PS_UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_UPPER_BASEDIR}  --datadir=$ps_master_datadir  --port=$PORT_MASTER --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_master.err --socket=$WORKDIR/ps_master.sock --log-output=none > $WORKDIR/logs/ps_master.err 2>&1 &

  startup_check $WORKDIR/ps_master.sock
  ${PS_UPPER_BASEDIR}/bin/mysql_upgrade --socket=$WORKDIR/ps_master.sock -uroot > $WORKDIR/logs/ps_rpl_master_upgrade.log 2>&1

  $PS_LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps_master.sock -u root shutdown

  ${PS_UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${PS_UPPER_BASEDIR}  --datadir=$ps_master_datadir  --port=$PORT_MASTER --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=101 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/ps_master.err --socket=$WORKDIR/ps_master.sock --log-output=none > $WORKDIR/logs/ps_master.err 2>&1 &

  startup_check $WORKDIR/ps_master.sock

  #Check replication status
  SLAVE_IO_STATUS=`${PS_LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_IO_Running | awk '{ print $2 }'`
  SLAVE_SQL_STATUS=`${PS_LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/ps_slave.sock -Bse "show slave status\G" | grep Slave_SQL_Running | awk '{ print $2 }'`

  if [ -z "$SLAVE_IO_STATUS" -o -z "$SLAVE_SQL_STATUS" ] ; then
    echoit "Error : Replication is not running, please check.."
    exit
  fi

  echoit "Replication status after master upgrade : Slave_IO_Running=$SLAVE_IO_STATUS - Slave_SQL_Running=$SLAVE_SQL_STATUS"
  ${PS_UPPER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_master.sock shutdown
  ${PS_UPPER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/ps_slave.sock shutdown
}
rpl_test
rpl_test gtid
rpl_test mts

