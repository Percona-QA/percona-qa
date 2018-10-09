#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test percona server with proxysql

#Bash internal configuration
#
set -o nounset    # no undefined variables

# Global variables
declare ADDR="127.0.0.1"
declare -i RPORT=$(( (RANDOM%21 + 10)*1000 ))
declare LADDR="$ADDR:$(( RPORT + 8 ))"
declare SUSER=root
declare SPASS=
declare SBENCH="sysbench"
declare SCRIPT_PWD=$(cd `dirname $0` && pwd)
declare -i PS_START_TIMEOUT=60
declare WORKDIR
declare BUILD_NUMBER=100
declare ROOT_FS
declare -i SDURATION=30
declare -i TSIZE=500
declare -i NUMT=16
declare -i TCOUNT=16
declare PSBASE
declare PS_TAR
declare PS_BASEDIR
declare MID
declare SYSBENCH_OPTIONS
declare PROXYSQL_BASE

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
  echo "  -w, --workdir       Specify work directory"
  echo "  -b, --build-number  Specify work build directory"
  echo "  -h, --help          Print script usage information"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:h --longoptions=workdir:,build-number:,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- "$go_out"
fi

if [[ $go_out == " --" ]];then
  usage
  exit 1
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -w | --workdir )
    WORKDIR="$2"
    if [[ ! -d "$WORKDIR" ]]; then
      echo "ERROR: Workdir ($WORKDIR) directory does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -b | --build-number )
    BUILD_NUMBER="$2"
    shift 2
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

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

# generic variables
if [[ -z "$WORKDIR" ]]; then
  WORKDIR=${PWD}
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="100"
fi

ROOT_FS=$WORKDIR
cd $WORKDIR

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/ps_proxysql_test.log; fi
}

#Kill existing mysqld process
ps -ef | grep 'ps[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

#Check PS binary tar ball
PS_TAR=`ls -1td ?ercona-?erver* | grep ".tar" | head -n1`
if [ ! -z $PS_TAR ];then
  tar -xzf $PS_TAR
  PSBASE=`ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1`
  if [[ -z $PSBASE ]]; then
    echo "ERROR! Could not find Percona Server directory. Terminating"
    exit 1
  fi
  export PATH="$ROOT_FS/$PSBASE/bin:$PATH"
fi
PS_BASEDIR="${ROOT_FS}/$PSBASE"

#Check ProxySQL binary tar ball
PROXYSQL_TAR=$(ls -1td proxysql-1* | grep ".tar" | head -n1)
if [ ! -z $PROXYSQL_TAR ];then
  tar -xzf $PROXYSQL_TAR
  PROXYSQL_BASE=$(ls -1td proxysql-1* | grep -v ".tar" | head -n1)
  if [[ -z $PROXYSQL_BASE ]]; then
    echo "ERROR! Could not find ProxySQL directory. Terminating"
    exit 1
  fi
  export PATH="$ROOT_FS/$PROXYSQL_BASE/usr/bin:$PATH"
fi
PROXYSQL_BASE="${ROOT_FS}/$PROXYSQL_BASE"

#"Looking for ProxySQL executable"
if [[ ! -x $PROXYSQL_BASE/usr/bin/proxysql ]]; then
  echo "ERROR! Could not find proxysql executable in $PROXYSQL_BASE/usr/bin"
  exit 1
fi

#Check sysbench
if [[ ! -e `which sysbench` ]];then
    echoit "Sysbench not found"
    exit 1
fi
echoit "Note: Using sysbench at $(which sysbench)"

#sysbench command should compatible with versions 0.5 and 1.0
sysbench_run(){
  local TEST_TYPE="$1"
  local DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-storage-engine=innodb --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "insert_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=30 --max-requests=1870000000 --mysql-db=$DB --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-storage-engine=innodb --mysql-db=$DB --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    elif [ "$TEST_TYPE" == "insert_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB  --threads=$NUMT --time=30 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

function sysbench_load(){
  local DATABASE_NAME=$1
  local SOCKET=$2
  echoit "Sysbench Run: Prepare stage (Database: $DATABASE_NAME)"
  sysbench_run load_data $DATABASE_NAME
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=root --mysql-socket=$SOCKET prepare  > $WORKDIR/logs/sysbench_prepare.txt 2>&1
  check_cmd $? "Failed to execute sysbench prepare stage"
}

function sysbench_rw_run(){
  local DATABASE_NAME=$1
  local USER=$2
  #OLTP RW run on master
  echoit "OLTP RW run on master (Database: $DATABASE_NAME)"
  sysbench_run oltp $DATABASE_NAME
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=$USER --mysql-password=test --mysql-port=6033 --mysql-host=127.0.0.1 run  > $WORKDIR/logs/sysbench_master_rw.log 2>&1
  check_cmd $? "Failed to execute sysbench oltp read/write run"
}

function sysbench_insert_run(){
  local DATABASE_NAME=$1
  local USER=$2
  echoit "Sysbench insert run (Database: $DATABASE_NAME)"
  sysbench_run insert_data $DATABASE_NAME
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=$USER --mysql-password=test --mysql-port=6033 --mysql-host=127.0.0.1 run  > $WORKDIR/logs/sysbench_insert.log 2>&1
  check_cmd $? "Failed to execute sysbench insert run"
}
 
MYSQL_VERSION=$(${PS_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${PS_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PS_BASEDIR}"
else
  MID="${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure  --basedir=${PS_BASEDIR}"
fi

#Check command failure
check_cmd(){
  local MPID=$1
  local ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echoit "ERROR: $ERROR_MSG. Terminating!"; exit 1; fi
}

function ps_start(){
  local INTANCES="$1"
  if [ -z $INTANCES ];then
    INTANCES=1
  fi
  for i in `seq 1 $INTANCES`;do
    local RBASE1="$((RPORT + ( 100 * $i )))"
    if ps -ef | grep  "\--port=${RBASE1}"  | grep -qv grep  ; then
      echoit "INFO! Another mysqld server running on port: ${RBASE1}. Using different port"
      RBASE1="$(( (RPORT + ( 100 * $i )) + 10 ))"
    fi
    echoit "Starting independent PS node${i}.."
    local node="${WORKDIR}/psnode${i}"
    rm -rf $node
    if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
      mkdir -p $node
    fi
    # Creating PS configuration file
    rm -rf ${PS_BASEDIR}/n${i}.cnf
    echo "[mysqld]" > ${PS_BASEDIR}/n${i}.cnf
    echo "basedir=${PS_BASEDIR}" >> ${PS_BASEDIR}/n${i}.cnf
    echo "datadir=$node" >> ${PS_BASEDIR}/n${i}.cnf
    echo "log-error=$WORKDIR/logs/psnode${i}.err" >> ${PS_BASEDIR}/n${i}.cnf
    echo "socket=/tmp/ps${i}.sock" >> ${PS_BASEDIR}/n${i}.cnf
    echo "port=$RBASE1" >> ${PS_BASEDIR}/n${i}.cnf
    echo "innodb_file_per_table" >> ${PS_BASEDIR}/n${i}.cnf
    echo "log-bin=mysql-bin" >> ${PS_BASEDIR}/n${i}.cnf
    echo "binlog-format=ROW" >> ${PS_BASEDIR}/n${i}.cnf
    echo "log-slave-updates" >> ${PS_BASEDIR}/n${i}.cnf
    echo "relay_log_recovery=1" >> ${PS_BASEDIR}/n${i}.cnf
    echo "binlog-stmt-cache-size=1M">> ${PS_BASEDIR}/n${i}.cnf
    echo "sync-binlog=0">> ${PS_BASEDIR}/n${i}.cnf
    echo "master-info-repository=TABLE" >> ${PS_BASEDIR}/n${i}.cnf
    echo "relay-log-info-repository=TABLE" >> ${PS_BASEDIR}/n${i}.cnf
    echo "core-file" >> ${PS_BASEDIR}/n${i}.cnf
    echo "log-output=none" >> ${PS_BASEDIR}/n${i}.cnf
    echo "server-id=10${i}" >> ${PS_BASEDIR}/n${i}.cnf
    echo "report-host=$ADDR" >> ${PS_BASEDIR}/n${i}.cnf
    echo "report-port=$RBASE1" >> ${PS_BASEDIR}/n${i}.cnf
    echo "default-storage-engine=INNODB" >> ${PS_BASEDIR}/n${i}.cnf
    echo "gtid-mode=ON" >> ${PS_BASEDIR}/n${i}.cnf
    echo "enforce-gtid-consistency" >> ${PS_BASEDIR}/n${i}.cnf

    ${MID} --datadir=$node  > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;

    ${PS_BASEDIR}/bin/mysqld --defaults-file=${PS_BASEDIR}/n${i}.cnf > $WORKDIR/logs/psnode${i}.err 2>&1 &

    for X in $(seq 0 ${PS_START_TIMEOUT}); do
      sleep 1
      if ${PS_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps${i}.sock ping > /dev/null 2>&1; then
        break
      fi
      if [ $X -eq ${PS_START_TIMEOUT} ]; then
        echoit "PS startup failed.."
        grep "ERROR" ${WORKDIR}/logs/psnode${i}.err
        exit 1
        fi
    done
    
  done
}

function proxysql_start(){
  local INTANCES=$1
  local READ_HG=100
  local WRITE_HG=200
  local RW_HG=300
  echoit "Starting ProxySQL..."
  rm -rf $WORKDIR/proxysql_db; mkdir $WORKDIR/proxysql_db
  $PROXYSQL_BASE/usr/bin/proxysql -D $WORKDIR/proxysql_db  $WORKDIR/proxysql_db/proxysql.log &
  sleep 10
  for i in `seq 1 $INTANCES`; do
    local PORT=$(${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps${i}.sock -Bse'select @@port')
    ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "INSERT INTO mysql_servers (hostname,hostgroup_id,port) VALUES ('127.0.0.1',$WRITE_HG,$PORT);"
    ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "INSERT INTO mysql_servers (hostname,hostgroup_id,port) VALUES ('127.0.0.1',$READ_HG,$PORT);"
    ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "INSERT INTO mysql_servers (hostname,hostgroup_id,port) VALUES ('127.0.0.1',$RW_HG,$PORT);"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps${i}.sock -e"create user monitor@'%' identified with mysql_native_password by 'monitor';create user testuser_W@'%' identified with mysql_native_password by 'test';grant all on *.* to testuser_W@'%';create user testuser_R@'%' identified with mysql_native_password by 'test';grant all on *.* to testuser_R@'%';create user testuser_RW@'%' identified with mysql_native_password by 'test';grant all on *.* to testuser_RW@'%';"
  done
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"
  
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "insert into mysql_users (username,password,active,default_hostgroup,default_schema) values ('testuser_W','test',1,$READ_HG,'sbtest_db');"
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "insert into mysql_users (username,password,active,default_hostgroup,default_schema) values ('testuser_R','test',1,$WRITE_HG,'sbtest_db');"
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "insert into mysql_users (username,password,active,default_hostgroup,default_schema) values ('testuser_RW','test',1,$RW_HG,'sbtest_db');"
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "LOAD MYSQL USERS TO RUNTIME;SAVE MYSQL USERS TO DISK;"
  
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "insert into mysql_query_rules (username,destination_hostgroup,active,flagIN,retries,match_digest,apply) values('testuser_RW',$RW_HG,1,100,3,'^INSERT ',1);"
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "insert into mysql_query_rules (username,destination_hostgroup,active,flagIN,retries,match_digest,apply) values('testuser_RW',$RW_HG,1,100,3,'^UPDATE ',1);"
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "insert into mysql_query_rules (username,destination_hostgroup,active,flagIN,retries,match_digest,apply) values('testuser_RW',$RW_HG,1,100,3,'^DELETE ',1);"
  ${PS_BASEDIR}/bin/mysql --user=admin --password=admin --host=127.0.0.1 --port=6032 --default-auth=mysql_native_password -e "LOAD MYSQL QUERY RULES TO RUNTIME;SAVE MYSQL QUERY RULES TO DISK;"
}

function proxysql_qa(){
  #PS server initialization
  echoit "PS server initialization"
  ps_start 3
  proxysql_start 3
  
  ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_db;create database sbtest_db;"
  ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists sbtest_db;create database sbtest_db;"
  ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e "drop database if exists sbtest_db;create database sbtest_db;"

  sysbench_load sbtest_db "/tmp/ps1.sock"
  sysbench_load sbtest_db "/tmp/ps2.sock"
  sysbench_load sbtest_db "/tmp/ps3.sock"

  sysbench_insert_run sbtest_db "testuser_W"
  sysbench_insert_run sbtest_db "testuser_W"
  sysbench_insert_run sbtest_db "testuser_W"
  
  sysbench_rw_run sbtest_db "testuser_RW"
  sysbench_rw_run sbtest_db "testuser_RW"
  sysbench_rw_run sbtest_db "testuser_RW"
  
  sleep 5
  
  $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
  $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
}

proxysql_qa