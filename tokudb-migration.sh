#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
WORKDIR=${PWD}
BACKP_DIR="${WORKDIR}/backup"
LOG_DIR="${WORKDIR}/logs"
TOKU_DIR="${WORKDIR}/tokudb_files"
BASEDIR_55="/sda/workdir/mysql-server-install"
BASEDIR_56="/sda/workdir/Percona-Server-5.6.27-rel75.0-Linux.x86_64"
MYSQLD_START_TIMEOUT=60
SBENCH="sysbench"
INNOBACKUP="innobackupex"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> /${WORKDIR}/tokudb_migration.log; fi
}

start_mysql_55(){
  ${BASEDIR_55}/bin/mysqld --no-defaults $1 --basedir=${BASEDIR_55} --tmpdir=${BASEDIR_55}/tmp --datadir=${BASEDIR_55}/data  --socket=${BASEDIR_55}/socket.sock --port=${PORT} --log-error=${BASEDIR_55}/log/master.err > ${BASEDIR_55}/log/master.err 2>&1 &
  MPID="$!"
  for X in $(seq 0 $MYSQLD_START_TIMEOUT); do
    sleep 1
    if ${BASEDIR_55}/bin/mysqladmin -uroot -S${BASEDIR_55}/socket.sock ping > /dev/null 2>&1; then
      break
    fi
    if [ "${MPID}" == "" ]; then
      echoit "Error! server not started.. Terminating!"
      egrep -i "ERROR|ASSERTION"  ${BASEDIR_55}/log/master.err
      exit 1
    fi
  done
}

stop_mysql_55(){
  timeout --signal=9 20s ${BASEDIR_56}/bin/mysqladmin -uroot --socket=${BASEDIR_56}/socket.sock shutdown > /dev/null 2>&1
  sleep 5
}

start_mysql_56(){
  ${BASEDIR_56}/bin/mysqld --no-defaults $1 --basedir=${BASEDIR_56} --tmpdir=${BASEDIR_56}/tmp --datadir=${BASEDIR_56}/data  --socket=${BASEDIR_56}/socket.sock --port=${PORT} --log-error=${BASEDIR_56}/log/master.err > ${BASEDIR_56}/log/master.err 2>&1 &
  MPID="$!"
  for X in $(seq 0 $MYSQLD_START_TIMEOUT); do
    sleep 1
    if ${BASEDIR_56}/bin/mysqladmin -uroot -S${BASEDIR_56}/socket.sock ping > /dev/null 2>&1; then
      break
    fi
    if ! ps -p ${MPID} > /dev/null; then
      echoit "Error! server not started.. Terminating!"
      egrep -i "ERROR|ASSERTION" ${BASEDIR_56}/log/master.err
      exit 1
    fi
  done
}

stop_mysql_56(){
  timeout --signal=9 20s ${BASEDIR_56}/bin/mysqladmin -uroot --socket=${BASEDIR_56}/socket.sock shutdown > /dev/null 2>&1
  sleep 5
}

echoit "Starting TokuDb migration."
# Kill existing mysqld process
echoit "Killing existing mysqld process."
stop_mysql_55
stop_mysql_56

# Clean existing data files
echoit "Cleaning existing data files."
rm -Rf ${BASEDIR_55}/data ${BASEDIR_55}/log ${BASEDIR_55}/tmp
mkdir ${BASEDIR_55}/data ${BASEDIR_55}/log ${BASEDIR_55}/tmp

rm -Rf ${BASEDIR_56}/data ${BASEDIR_56}/log ${BASEDIR_56}/tmp
mkdir ${BASEDIR_56}/data ${BASEDIR_56}/log ${BASEDIR_56}/tmp

# Clean work directory
echoit "Cleaning existing work directory."
rm -Rf ${BACKP_DIR} ${LOG_DIR} ${TOKU_DIR} ${WORKDIR}/*.csv ${WORKDIR}/*.sql
mkdir -p ${BACKP_DIR} ${LOG_DIR} ${TOKU_DIR}

#Start 55 server for dataload
echoit "Starting MySQL-5.5 mysqld process."
# Run mysql_install_db
if [ -r ${BASEDIR_55}/bin/mysql_install_db ]; then
  ${BASEDIR_55}/bin/mysql_install_db --no-defaults --force --basedir=${BASEDIR_55} --datadir=${BASEDIR_55}/data > ${LOG_DIR}/mysql55_install.log 2>&1
elif [ -r ${BASEDIR_55}/scripts/mysql_install_db ]; then
  ${BASEDIR_55}/scripts/mysql_install_db --no-defaults --force --basedir=${BASEDIR_55} --datadir=${BASEDIR_55}/data > ${LOG_DIR}/mysql55_install.log 2>&1
else
  echo 'mysql_install_db not found in scripts nor bin directories';
  exit 1
fi

# Load jemalloc lib
if [ -r /usr/lib64/libjemalloc.so.1 ]; then
  export LD_PRELOAD=/usr/lib64/libjemalloc.so.1
elif [ -r /usr/lib/x86_64-linux-gnu/libjemalloc.so.1 ]; then
  export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.1
elif [ -r ${BASEDIR_55}/lib/mysql/libjemalloc.so.1 ]; then
  export LD_PRELOAD=${BASEDIR_55}/lib/mysql/libjemalloc.so.1
else
  echo 'Error: jemalloc not found, please install it first';
  exit 1;
fi

MYEXTRA=""
start_mysql_55 $MYEXTRA

${BASEDIR_55}/bin/mysql -uroot --socket=${BASEDIR_55}/socket.sock -e "create database if not exists test; create database if not exists innotest"

#Load TokuDB tables
echoit "Loading tokudb tables."
$SBENCH --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --mysql-table-engine=tokudb --num-threads=10 --oltp-tables-count=10  --oltp-table-size=20000 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${BASEDIR_55}/socket.sock   run > ${LOG_DIR}/sysbench-toku-prepare.txt 2>&1

#Load Innodb tables
echoit "Loading innodb tables."
$SBENCH --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --mysql-table-engine=innodb --num-threads=10 --oltp-tables-count=10  --oltp-table-size=20000 --mysql-db=innotest --mysql-user=root --db-driver=mysql --mysql-socket=${BASEDIR_55}/socket.sock   run > ${LOG_DIR}/sysbench-innodb-prepare.txt 2>&1

# Create partitions for tokudb tables
echoit "Creating partitions for tokudb tables."
${BASEDIR_55}/bin/mysql -uroot --socket=${BASEDIR_55}/socket.sock -Bse "select concat('ALTER TABLE ',table_schema,'.',table_name,' PARTITION BY HASH(id) PARTITIONS 8;') as a FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='test'" > ${WORKDIR}/alter_table_partion.sql

${BASEDIR_55}/bin/mysql -uroot --socket=${BASEDIR_55}/socket.sock test < ${WORKDIR}/alter_table_partion.sql

echoit "Dumping TokuDB schema.."
${BASEDIR_55}/bin/mysqldump --no-data -uroot --socket=${BASEDIR_55}/socket.sock test > ${WORKDIR}/toku_schema.sql
${BASEDIR_55}/bin/mysql -uroot --socket=${BASEDIR_55}/socket.sock -e "SELECT * FROM INFORMATION_SCHEMA.TOKUDB_FILE_MAP INTO OUTFILE '${WORKDIR}/IS_55.csv'"

# Create backup of non-TokuDB databases
echoit "Creating  backup of non-TokuDB databases."
$INNOBACKUP  --user=root --socket=${BASEDIR_55}/socket.sock --datadir=${BASEDIR_55}/data --databases="innotest mysql performance_schema" ${BACKP_DIR} > ${LOG_DIR}/innobackupex.log 2&>1
BACKUP_LOC=`ls -rt ${BACKP_DIR} | tail -1`

$INNOBACKUP --apply-log ${BACKP_DIR}/$BACKUP_LOC > ${LOG_DIR}/innobackupex_prepare.log 2&>1
timeout --signal=9 20s ${BASEDIR_55}/bin/mysqladmin -uroot --socket=${BASEDIR_55}/socket.sock shutdown > /dev/null 2>&1

find ${BASEDIR_55}/data -type f -name "*toku*" | xargs cp -t ${WORKDIR}/tokudb_files

cp -r ${BACKP_DIR}/$BACKUP_LOC/* ${BASEDIR_56}/data

export LD_PRELOAD=""
#Start 56 server without TokuDB plugin
echoit "Starting 56 server without TokuDB plugin for non tokudb tables migration."
MYEXTRA=""
start_mysql_56 $1

${BASEDIR_56}/bin/mysql_upgrade -uroot --socket=${BASEDIR_56}/socket.sock > ${LOG_DIR}/mysql_upgrade.log 2>&1
echoit "mysql_upgrade completed successfully for non tokudb tables."
stop_mysql_56

# Load jemalloc lib
if [ -r /usr/lib64/libjemalloc.so.1 ]; then
  export LD_PRELOAD=/usr/lib64/libjemalloc.so.1
elif [ -r /usr/lib/x86_64-linux-gnu/libjemalloc.so.1 ]; then
  export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.1
elif [ -r ${BASEDIR_56}/lib/mysql/libjemalloc.so.1 ]; then
  export LD_PRELOAD=${BASEDIR_56}/lib/mysql/libjemalloc.so.1
else
  echoit "Error: jemalloc not found, please install it first"
  exit 1;
fi

#Start 56 server with TokuDB plugin
echoit "Starting 56 server with TokuDB plugin for tokudb migration."
MYEXTRA=""
MYEXTRA="--plugin-load=tokudb=ha_tokudb.so"
start_mysql_56 ${MYEXTRA}
echoit "Loading tokudb schema to mysql 5.6"
${BASEDIR_56}/bin/mysql -uroot --socket=${BASEDIR_56}/socket.sock -e "create database if not exists test"
${BASEDIR_56}/bin/mysql -uroot --socket=${BASEDIR_56}/socket.sock test < ${WORKDIR}/toku_schema.sql

stop_mysql_56

rm -Rf ${BASEDIR_56}/data/*toku*

cp -r  ${WORKDIR}/tokudb_files/* ${BASEDIR_56}/data/
echoit "Starting server with --tokudb-strip-frm-data=TRUE for tokudb data migration."
MYEXTRA="--plugin-load=tokudb=ha_tokudb.so --tokudb-strip-frm-data=TRUE"
start_mysql_56 ${MYEXTRA}

stop_mysql_56

MYEXTRA="--plugin-load=tokudb=ha_tokudb.so"
start_mysql_56 ${MYEXTRA}

${BASEDIR_56}/bin/mysql -uroot --socket=${BASEDIR_56}/socket.sock -e "SELECT * FROM INFORMATION_SCHEMA.TOKUDB_FILE_MAP INTO OUTFILE '${WORKDIR}/IS_56.csv'"

diff --brief <(sort ${WORKDIR}/IS_55.csv) <(sort ${WORKDIR}/IS_56.csv) >/dev/null
comp_value=$?

if [ $comp_value -eq 1 ]
then
    echoit "Found difference in INFORMATION_SCHEMA.TOKUDB_FILE_MAP INTO tables. Please check..."
else
    echoit "TokuDB migration successful.."
fi
