#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test MySQL upgrade

# Bash internal configuration
#
set -o nounset    # no undefined variables
set -e

# Global variables
declare SBENCH="sysbench"
declare PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
declare WORKDIR=""
declare ROOT_FS=""
declare SCRIPT_PWD=$(cd `dirname $0` && pwd)
declare BUILD_NUMBER=""
declare SDURATION=""
declare TSIZE=""
declare NUMT=""
declare TCOUNT=""
declare SYSBENCH_OPTIONS=""
declare LOWER_BASEDIR=""
declare UPPER_BASEDIR=""
declare LOWER_MID
declare UPPER_MID
declare MYSQLD_START_TIMEOUT=60
declare TESTCASE=""
declare KEYRING_PLUGIN=""
declare INIT_OPT=""
declare ENCRYPTION=""

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
  echo "  -w, --workdir                     Specify work directory"
  echo "  -b, --build-number                Specify work build directory(For Jenkins automated runs only)"
  echo "  -l, --lower-base                  Specify PS/MS lower base directory"
  echo "  -u, --upper-base                  Specify PS/MS upper base directory"
  echo "  -o, --mysql-extra-options         Specify Mysql extra options used in innodb_options_test"
  echo "  -k, --keyring-plugin=[file|vault] Specify which keyring plugin to use(default keyring-file)"
  echo "  -t, --testcase=<testcases|all>    Run only following comma-separated list of testcases"
  echo "                                      non_partition_test"
  echo "                                      partition_test"
  echo "                                      compression_test"
  echo "                                      innodb_options_test"
  echo "                                      replication_test_gtid"
  echo "                                      replication_test_mts"
  echo "                                    If you specify 'all', the script will execute all testcases"
  echo ""
  echo "  -e, --with-encryption             Run the script with encryption feature"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:l:u:o:k:t:eh --longoptions=workdir:,build-number:,lower-base:,upper-base:,mysql-extra-options:,keyring-plugin:,testcase:,with-encryption,help \
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
    -l | --lower-base )
    LOWER_BASE="$2"
    shift 2
    ;;
    -u | --upper-base )
    UPPER_BASE="$2"
    shift 2
    ;;
    -o | --mysql-extra-options )
    MYSQL_EXTRA_OPTIONS="$2"
    shift 2
    ;;
    -k | --keyring-plugin )
    KEYRING_PLUGIN="$2"
    shift 2
    if [[ "$KEYRING_PLUGIN" != "file" ]] && [[ "$KEYRING_PLUGIN" != "vault" ]] ; then
      echo "ERROR: Invalid --keyring-plugin passed:"
      echo "  Please choose any of these keyring-plugin options: 'file' or 'vault'"
      exit 1
    fi
    ;;
    -t | --testcase )
    TESTCASE="$2"
	shift 2
    ;;
    -e | --with-encryption )
    shift
    ENCRYPTION=1
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER=1001
fi

if [ -z $WORKDIR ]; then
  WORKDIR=${PWD}
fi

if [ -z $ROOT_FS ]; then
  ROOT_FS=${WORKDIR}
fi

if [ ${ENCRYPTION} -eq 1 ]; then
  FULL_TESTCASE="${TESTCASE}_enc_${KEYRING_PLUGIN}"
else
  FULL_TESTCASE="${TESTCASE}"
fi

WORKDIR="${ROOT_FS}/${BUILD_NUMBER}-${FULL_TESTCASE}"

#Cleanup
if [ -d ${WORKDIR} ]; then
  rm -r ${WORKDIR}
fi
mkdir -p ${WORKDIR}/logs

if [ -z ${SDURATION} ]; then
  SDURATION=100
fi

if [ -z ${TSIZE} ]; then
  TSIZE=1000
fi

if [ -z ${NUMT} ]; then
  NUMT=10
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=10
fi

if [[ -z "$KEYRING_PLUGIN" ]]; then
  KEYRING_PLUGIN="file"
fi

if [[ ! -z "$TESTCASE" ]]; then
  IFS=', ' read -r -a TC_ARRAY <<< "$TESTCASE"
else
  TC_ARRAY=(all)
fi

if [[ -z "${MYSQL_EXTRA_OPTIONS:-}" ]]; then
  MYSQL_EXTRA_OPTIONS="--innodb_file_per_table=ON"
fi
#echo "Mysqld process will be started with extra options: $MYSQL_EXTRA_OPTIONS"

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
  tar cvzfP $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $ROOT_FS/*/logs || true
}

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/upgrade_testing.log; fi
}

if [ "$ENCRYPTION" == 1 ];then
  if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
    echoit "Setting up vault server"
    mkdir $WORKDIR/vault
    rm -rf $WORKDIR/vault/*
    killall vault
    echoit "********************************************************************************************"
    ${SCRIPT_PWD}/vault_test_setup.sh --workdir=$WORKDIR/vault --use-ssl
    echoit "********************************************************************************************"
  fi
fi

trap cleanup EXIT KILL

cd $ROOT_FS

if [ ! -d $ROOT_FS/test_db ]; then
  git clone https://github.com/datacharmer/test_db.git
fi

LOWER_TAR=`readlink -e ${LOWER_BASE}* | grep ".tar" | head -n1`
UPPER_TAR=`readlink -e ${UPPER_BASE}* | grep ".tar" | head -n1`

if [ ! -z $LOWER_TAR ];then
  tar -xzf $LOWER_TAR
  LOWER_BASEDIR=`readlink -e ${LOWER_BASE}* | grep -v ".tar" | head -n1`
  export PATH="$LOWER_BASEDIR/bin:$PATH"
else
  LOWER_BASEDIR=`readlink -e ${LOWER_BASE}* | grep -v ".tar" | head -n1`
  if [ ! -z $LOWER_BASEDIR ]; then
    export PATH="$LOWER_BASEDIR/bin:$PATH"
  else
    echoit "ERROR! Could not find $LOWER_BASE binary"
    exit 1
  fi
fi

if [ ! -z $UPPER_TAR ];then
  tar -xzf $UPPER_TAR
  UPPER_BASEDIR=`readlink -e ${UPPER_BASE}* | grep -v ".tar" | head -n1`
  export PATH="$UPPER_BASEDIR/bin:$PATH"
else
  UPPER_BASEDIR=`readlink -e ${UPPER_BASE}* | grep -v ".tar" | head -n1`
  if [ ! -z $UPPER_BASEDIR ]; then
    export PATH="$UPPER_BASEDIR/bin:$PATH"
  else
    echoit "ERROR! Could not find $UPPER_BASE binary"
    exit 1
  fi
fi

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

mysqldatadir="${MYSQL_VARDIR}/mysqldata"
mkdir -p $mysqldatadir

# print mysql and mysqld versions for debugging
echoit "##### PS lower version #####"
echoit "$($LOWER_BASEDIR/bin/mysql --version)"
echoit "$($LOWER_BASEDIR/bin/mysqld --version)"
echoit "##### PS upper version #####"
echoit "$($UPPER_BASEDIR/bin/mysql --version)"
echoit "$($UPPER_BASEDIR/bin/mysqld --version)"

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
   $LOWER_BASEDIR/bin/mysql --socket=${WORKDIR}/mysql_lower.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

#Load jemalloc lib
if [ -r `find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then
  export LD_PRELOAD=`find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
elif [ -r $UPPER_BASEDIR/lib/mysql/libjemalloc.so.1 ]; then
  export LD_PRELOAD=$UPPER_BASEDIR/lib/mysql/libjemalloc.so.1
else
  echoit "Error: jemalloc not found, please install it first"
  exit 1;
fi


declare MYSQL_VERSION=$(${LOWER_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  LOWER_MID="${LOWER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${LOWER_BASEDIR}"
else
  LOWER_MID="${LOWER_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${LOWER_BASEDIR}"
fi

declare MYSQL_VERSION=$(${UPPER_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  UPPER_MID="${UPPER_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${UPPER_BASEDIR}"
else
  UPPER_MID="${UPPER_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${UPPER_BASEDIR}"
fi

function generate_cnf(){
  local BASE=$1
  local DATADIR=$2
  local PORT=$3
  local ARGS=$4
  echo "[mysqld]" > ${WORKDIR}/$ARGS.cnf
  echo "basedir=${BASE}" >> $WORKDIR/$ARGS.cnf
  echo "datadir=$DATADIR" >> $WORKDIR/$ARGS.cnf
  echo "port=$PORT" >> $WORKDIR/$ARGS.cnf
#  echo "innodb_file_per_table" >> $WORKDIR/$ARGS.cnf
  echo "default-storage-engine=InnoDB" >> $WORKDIR/$ARGS.cnf
  echo "binlog-format=ROW" >> $WORKDIR/$ARGS.cnf
  echo "log-bin=mysql-bin" >> $WORKDIR/$ARGS.cnf
  echo "server-id=101" >> $WORKDIR/$ARGS.cnf
  echo "gtid-mode=ON " >> $WORKDIR/$ARGS.cnf
  echo "log-slave-updates" >> $WORKDIR/$ARGS.cnf
  echo "enforce-gtid-consistency" >> $WORKDIR/$ARGS.cnf
  echo "master-info-repository=TABLE" >> $WORKDIR/$ARGS.cnf
  echo "relay-log-info-repository=TABLE" >> $WORKDIR/$ARGS.cnf
  echo "innodb_flush_method=O_DIRECT" >> $WORKDIR/$ARGS.cnf
  echo "core-file" >> $WORKDIR/$ARGS.cnf
  echo "secure-file-priv=" >> $WORKDIR/$ARGS.cnf
  echo "skip-name-resolve" >> $WORKDIR/$ARGS.cnf
  echo "log-error=$WORKDIR/logs/$ARGS.err" >> $WORKDIR/$ARGS.cnf
  echo "socket=$WORKDIR/$ARGS.sock" >> $WORKDIR/$ARGS.cnf
  echo "log-output=none" >> $WORKDIR/$ARGS.cnf
  if [[ "$ENCRYPTION" == 1 ]];then
    if check_for_version $MYSQL_VERSION "8.0.14" ; then
      echo "encrypt_binlog=ON" >> $WORKDIR/$ARGS.cnf
      echo "innodb_encrypt_tables=ON" >> $WORKDIR/$ARGS.cnf
    else
      echo "binlog_encryption=ON" >> $WORKDIR/$ARGS.cnf
      echo "default_table_encryption=ON" >> $WORKDIR/$ARGS.cnf
    fi
    echo "master_verify_checksum=on" >> $WORKDIR/$ARGS.cnf
    echo "binlog_checksum=crc32" >> $WORKDIR/$ARGS.cnf
    echo "innodb_temp_tablespace_encrypt=ON" >> $WORKDIR/$ARGS.cnf
    echo "encrypt-tmp-files=ON" >> $WORKDIR/$ARGS.cnf
    if check_for_version $MYSQL_VERSION "5.7.23" ; then
      echo "innodb_sys_tablespace_encrypt=ON" >> $WORKDIR/$ARGS.cnf
    fi
    if [[ "$KEYRING_PLUGIN" == "file" ]]; then
      echo "early-plugin-load=keyring_file.so" >> $WORKDIR/$ARGS.cnf
      echo "keyring_file_data=$DATADIR/keyring" >> $WORKDIR/$ARGS.cnf
      if check_for_version $MYSQL_VERSION "5.7.23" ; then
        INIT_OPT="--early-plugin-load=keyring_file.so --keyring_file_data=$DATADIR/keyring --innodb_sys_tablespace_encrypt=ON"
      fi
    elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
      echo "early-plugin-load=keyring_vault.so" >> $WORKDIR/$ARGS.cnf
      echo "keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf" >> $WORKDIR/$ARGS.cnf
      if check_for_version $MYSQL_VERSION "5.7.23" ; then
        INIT_OPT="--early-plugin-load=keyring_vault.so --keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf --innodb_sys_tablespace_encrypt=ON"
      fi
    fi
  fi

}
function check_conn(){
  local BASE=$1
  local ARGS=$2
  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${BASE}/bin/mysqladmin -uroot -S$WORKDIR/$ARGS.sock ping > /dev/null 2>&1; then
      break
    fi
    if [ $X -eq ${MYSQLD_START_TIMEOUT} ]; then
      echoit "MySQL startup failed.."
      grep "ERROR" $WORKDIR/logs/$ARGS.err
      exit 1
    fi
  done
}

function start_mysql_lower_main(){
  generate_cnf "$LOWER_BASEDIR" "$mysqldatadir" "$PORT" "mysql_lower"
  ${LOWER_MID} --datadir=$mysqldatadir $INIT_OPT ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/mysql_lower.err 2>&1 || exit 1;
  ${LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_lower.cnf --basedir=$LOWER_BASEDIR --datadir=$mysqldatadir --port=$PORT ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/mysql_lower.err 2>&1 &
  check_conn "${LOWER_BASEDIR}" "mysql_lower"
  ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_lower.sock -e"drop database if exists test; create database test"
}

function create_regular_tbl(){
  local SOCKET=$1
  echoit "Sysbench Run: Creating InnoDB  tables"
  sysbench_run innodb test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_innodb_prepare.txt

  echoit "Sysbench Run: Creating MyISAM tables"
  echo "CREATE DATABASE sysbench_myisam_db;" | $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root || true
  sysbench_run myisam sysbench_myisam_db
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_myisam_prepare.txt
  
  $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root sysbench_myisam_db -e"CREATE TABLE sbtest_mrg like sbtest1" || true
  
  SBTABLE_LIST=`$LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root -Bse "SELECT GROUP_CONCAT(table_name SEPARATOR ',') FROM information_schema.tables WHERE table_schema='sysbench_myisam_db' and table_name!='sbtest_mrg'"`
 
  $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root sysbench_myisam_db -e"ALTER TABLE sbtest_mrg UNION=($SBTABLE_LIST), ENGINE=MRG_MYISAM" || true
  
  echoit "Loading sakila test database"
  $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root < ${SCRIPT_PWD}/sample_db/sakila.sql
  
  echoit "Loading world test database"
  $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root < ${SCRIPT_PWD}/sample_db/world.sql
  
  echoit "Loading employees database with innodb engine.."
  create_emp_db employee_1 innodb employees.sql
  
  echoit "Loading employees database with myisam engine.."
  create_emp_db employee_3 myisam employees.sql
  
}
function test_row_format_tbl(){
  local SOCKET=$1
  ROW_FORMAT=(DEFAULT DYNAMIC COMPRESSED REDUNDANT COMPACT)
  $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root -e "drop database if exists test_row_format;create database test_row_format;"
  for i in `seq 1 5`;do
    $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root -e "CREATE TABLE test_row_format.sbtest$i (id int(11) NOT NULL AUTO_INCREMENT,k int(11) NOT NULL DEFAULT '0',c char(120) NOT NULL DEFAULT '',pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k)) ROW_FORMAT=${ROW_FORMAT[$i-1]};"
  done
  sysbench /usr/share/sysbench/oltp_insert.lua --mysql-db=test_row_format --mysql-user=root --db-driver=mysql --mysql-socket=$SOCKET --threads=5 --tables=5 --table-size=1000 --time=10 run > $WORKDIR/logs/sysbench_test_row_format.log 2>&1
}

# Upgrade mysqld with higher version
function start_mysql_upper_main(){
  echoit "Upgrading mysqld with higher version"
  generate_cnf "${UPPER_BASEDIR}" "$mysqldatadir" "$PORT" "mysql_upper"
  ${UPPER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_upper.cnf --basedir=${UPPER_BASEDIR} --datadir=$mysqldatadir --port=$PORT ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/mysql_upper.err 2>&1 &
  sleep 20
  check_conn "${UPPER_BASEDIR}" "mysql_upper"

  $UPPER_BASEDIR/bin/mysql_upgrade -S $WORKDIR/mysql_upper.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

  for i in "${TC_ARRAY[@]}"; do
	if [[ "$i" == "partition_test" ]]; then
      echo "ALTER TABLE sysbench_partition.sbtest1 COALESCE PARTITION 2;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_upper.sock -u root || true
      echo "ALTER TABLE sysbench_partition.sbtest2 REORGANIZE PARTITION;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_upper.sock -u root || true
      echo "ALTER TABLE sysbench_partition.sbtest3 ANALYZE PARTITION p1;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_upper.sock -u root || true
      echo "ALTER TABLE sysbench_partition.sbtest4 CHECK PARTITION p2;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_upper.sock -u root || true
    fi
  done
   
  $UPPER_BASEDIR/bin/mysql -S $WORKDIR/mysql_upper.sock  -u root -e "show global variables like 'version';"
}

function start_mysql_downgrade_main(){
  $LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/mysql_lower.sock -u root shutdown
  start_mysql_upper_main

  echoit "Downgrade testing with mysqlddump and reload.."
  $UPPER_BASEDIR/bin/mysqldump --set-gtid-purged=OFF  --triggers --routines --socket=$WORKDIR/mysql_upper.sock -uroot --databases `$UPPER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_upper.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"` > $WORKDIR/dbdump.sql 2>&1

  #Remove data dir if it exists before MySQL initialization
  if [ -d ${MYSQL_VARDIR}/mysql_lower_down ]; then
     echo "Removing data dir before MySQL initialization"
     rm -fr ${MYSQL_VARDIR}/mysql_lower_down
  fi
  mysqldatadir="${MYSQL_VARDIR}/mysql_lower_down"
  PORT1=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  generate_cnf "${LOWER_BASEDIR}" "$mysqldatadir" "$PORT1" "mysql_lower_down"
  ${LOWER_MID} --datadir=$mysqldatadir $INIT_OPT ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/mysql_lower_down.err 2>&1 || exit 1;
  ${LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_lower_down.cnf ${MYSQL_EXTRA_OPTIONS} > $WORKDIR/logs/mysql_lower_down.err 2>&1 &
  check_conn "${LOWER_BASEDIR}" "mysql_lower_down"
  if [ -f $WORKDIR/test/sbtest1copy.ibd ]; then
     echo "Moving data existing outside data dir"
     mv $WORKDIR/test/sbtest1copy.ibd $WORKDIR/../
  fi
  ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_lower_down.sock -e"drop database if exists test; create database test"
}

function mysql_downgrade_datacheck(){
  ${LOWER_BASEDIR}/bin/mysql --socket=$WORKDIR/mysql_lower_down.sock -uroot < $WORKDIR/dbdump.sql 2>&1
  
  CHECK_DBS=`$UPPER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_upper.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"`
  
  echoit "Checking table status..."
  ${LOWER_BASEDIR}/bin/mysqlcheck -uroot --socket=$WORKDIR/mysql_lower_down.sock --check-upgrade --databases $CHECK_DBS 2>&1

  #Stop mysqld processes for lower and upper version
  ${LOWER_BASEDIR}/bin/mysqladmin -uroot --socket=$WORKDIR/mysql_lower_down.sock shutdown
  ${UPPER_BASEDIR}/bin/mysqladmin -uroot --socket=$WORKDIR/mysql_upper.sock shutdown

  #Clean data dir
  rm -fr ${MYSQL_VARDIR}/*
}

function non_partition_test(){
  local SOCKET=${1:-}	

  echoit "##### START: non_partition_test #####"
  echoit "Creating non partitioned tables"
  start_mysql_lower_main
  echoit "Create regular tables with different storage engines"
  create_regular_tbl $SOCKET
  
  echoit "Create tables with different row formats"
  test_row_format_tbl $SOCKET
  
  if [ "$ENCRYPTION" == 1 ];then
    $LOWER_BASEDIR/bin/mysql -uroot --socket=$SOCKET test -e "CREATE TABLESPACE test_gen_ts1 ADD DATAFILE 'test_gen_ts1.ibd' ENCRYPTION='Y'"  2>&1
    $LOWER_BASEDIR/bin/mysql -uroot --socket=$SOCKET test -e "CREATE TABLE test_gen_ts_tb1(id int auto_increment, str varchar(32), primary key(id)) TABLESPACE test_gen_ts1" 2>&1
    $LOWER_BASEDIR/bin/mysql -uroot --socket=$SOCKET test -e "CREATE TABLE test_sys_ts_tb1(id int auto_increment, str varchar(32), primary key(id)) TABLESPACE=innodb_system ENCRYPTION='Y'" 2>&1
    local NUM_ROWS=$(shuf -i 50-100 -n 1)
    for i in `seq 1 $NUM_ROWS`; do
      local STRING=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
      $LOWER_BASEDIR/bin/mysql -uroot --socket=$SOCKET test -e "INSERT INTO test_gen_ts_tb1 (str) VALUES ('${STRING}')"
      $LOWER_BASEDIR/bin/mysql -uroot --socket=$SOCKET test -e "INSERT INTO test_sys_ts_tb1 (str) VALUES ('${STRING}')"
    done
    ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_lower.sock -e"drop database if exists test_encrypt; create database test_encrypt"
    echoit "Sysbench Run: Prepare stage"
    sysbench_run innodb test_encrypt
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_test_encrypt_prepare.txt
    for j in `seq 1 5`; do
      ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_lower.sock -e"ALTER TABLE test_encrypt.sbtest$j TABLESPACE=innodb_system"
	done
    for j in `seq 6 10`; do
      $LOWER_BASEDIR/bin/mysql -uroot --socket=$SOCKET test -e "CREATE TABLESPACE test_encrypt_gen_ts1 ADD DATAFILE 'test_encrypt_gen_ts1.ibd' ENCRYPTION='Y'"  2>&1
      ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_lower.sock -e"ALTER TABLE test_encrypt.sbtest$j TABLESPACE=test_encrypt_gen_ts1"
	done
  fi

  if [ -r ${UPPER_BASE}/lib/mysql/plugin/ha_tokudb.so ]; then
    if [ -r ${LOWER_BASEDIR}/lib/mysql/plugin/ha_tokudb.so ]; then
      #Install TokuDB plugin
      echo "INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so'" | $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET
      $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET < ${SCRIPT_PWD}/TokuDB.sql
  
      echoit "Loading employees database with tokudb engine for upgrade testing.."
      #create_emp_db employee_5 tokudb employees.sql
    
      if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
        echoit "Loading employees partitioned database with tokudb engine for upgrade testing.."
        create_emp_db employee_6 tokudb employees_partitioned.sql
      fi
  
    fi
  fi

  if [ -r ${UPPER_BASEDIR}/lib/mysql/plugin/ha_rocksdb.so ]; then
    if [ -r ${LOWER_BASEDIR}/lib/mysql/plugin/ha_rocksdb.so ]; then
      #Install RocksDB plugin
      echo "INSTALL PLUGIN rocksdb SONAME 'ha_rocksdb.so'" | $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET
      $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET < ${SCRIPT_PWD}/MyRocks.sql
  
      echo "DROP DATABASE IF EXISTS rocksdb_test;CREATE DATABASE IF NOT EXISTS rocksdb_test; set global default_storage_engine = ROCKSDB " | $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET
  
      echoit "Sysbench rocksdb data load"
      sysbench_run rocksdb rocksdb_test
      $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_rocksdb_prepare.txt
    fi
  fi

  start_mysql_downgrade_main
  mysql_downgrade_datacheck
  echoit "##### END: non_partition_test #####"
}

function partition_test(){
  local SOCKET=$1

  echoit "##### START: partition_test #####"
  echoit "Creating partitioned tables"
  start_mysql_lower_main
  ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_lower.sock -e"drop database if exists sysbench_partition; create database sysbench_partition"
  echoit "Sysbench Run: Prepare stage"
  sysbench_run innodb sysbench_partition
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_partition_prepare.txt
	
  #Partition testing with sysbench data
  echo "ALTER TABLE sysbench_partition.sbtest1 PARTITION BY HASH(id) PARTITIONS 8;" | $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root || true
  echo "ALTER TABLE sysbench_partition.sbtest2 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root || true
  echo "ALTER TABLE sysbench_partition.sbtest3 PARTITION BY HASH(id) PARTITIONS 8;" | $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root || true
  echo "ALTER TABLE sysbench_partition.sbtest4 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $LOWER_BASEDIR/bin/mysql --socket=$SOCKET -u root || true
  
  echoit "Loading employees partitioned database with innodb engine.."
  create_emp_db employee_2 innodb employees_partitioned.sql
  
  if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
    echoit "Loading employees partitioned database with myisam engine.."
    create_emp_db employee_4 myisam employees_partitioned.sql
  fi

  if [ -r ${UPPER_BASE}/lib/mysql/plugin/ha_tokudb.so ]; then
    if [ -r ${LOWER_BASEDIR}/lib/mysql/plugin/ha_tokudb.so ]; then
      #Install TokuDB plugin
      echo "INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so'" | $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET
      $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET < ${SCRIPT_PWD}/TokuDB.sql
    
      if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
        echoit "Loading employees partitioned database with tokudb engine for upgrade testing.."
        #create_emp_db employee_6 tokudb employees_partitioned.sql
      fi
  
    fi
  fi

  if [ -r ${UPPER_BASEDIR}/lib/mysql/plugin/ha_rocksdb.so ]; then
    if [ -r ${LOWER_BASEDIR}/lib/mysql/plugin/ha_rocksdb.so ]; then
      #Install RocksDB plugin
      echo "INSTALL PLUGIN rocksdb SONAME 'ha_rocksdb.so'" | $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET
      $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET < ${SCRIPT_PWD}/MyRocks.sql
  
      echo "DROP DATABASE IF EXISTS rocksdb_test;CREATE DATABASE IF NOT EXISTS rocksdb_test; set global default_storage_engine = ROCKSDB " | $LOWER_BASEDIR/bin/mysql -uroot  --socket=$SOCKET
  
      if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
        echoit "Creating rocksdb partitioned tables"
        for i in `seq 1 10`; do
          ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "create table rocksdb_test.tbl_range${i} (id int auto_increment,str varchar(32),year_col int, primary key(id,year_col)) PARTITION BY RANGE (year_col) ( PARTITION p0 VALUES LESS THAN (1991), PARTITION p1 VALUES LESS THAN (1995),PARTITION p2 VALUES LESS THAN (2000))" 2>&1
          ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "CREATE TABLE rocksdb_test.tbl_list${i} (c1 INT, c2 INT ) PARTITION BY LIST(c1) ( PARTITION p0 VALUES IN (1, 3, 5, 7, 9),PARTITION p1 VALUES IN (2, 4, 6, 8) );" 2>&1
          ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "CREATE TABLE rocksdb_test.tbl_key${i} ( id INT NOT NULL PRIMARY KEY auto_increment, str_value VARCHAR(100)) PARTITION BY KEY() PARTITIONS 5;" 2>&1
          ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "CREATE TABLE rocksdb_test.tbl_sub_part${i} (id int, purchased DATE) PARTITION BY RANGE( YEAR(purchased) ) SUBPARTITION BY HASH( TO_DAYS(purchased) ) SUBPARTITIONS 2 ( PARTITION p0 VALUES LESS THAN (1990),PARTITION p1 VALUES LESS THAN (2000),PARTITION p2 VALUES LESS THAN MAXVALUE);" 2>&1
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
            ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "INSERT INTO rocksdb_test.tbl_range${j} (str,year_col) VALUES ('${STRING}',${ARR_YEAR[$rand_year]})"
            ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "INSERT INTO rocksdb_test.tbl_list${j} VALUES (${ARR_L1[$rand_list1]},${ARR_L2[$rand_list2]})"
            ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "INSERT INTO rocksdb_test.tbl_key${j} (str_value) VALUES ('${STRING}')"
            ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "INSERT INTO rocksdb_test.tbl_sub_part${j} VALUES (${i},'${ARR_DATE[$rand_sub]}')"
          done
        done
      fi
    fi
  fi
  
  start_mysql_downgrade_main
  mysql_downgrade_datacheck
  echoit "##### END: partition_test #####"
}

function compression_test(){
  local SOCKET=${1:-}

  echoit "##### START: compression_test #####"
  echoit "Creating data for compression test"
  start_mysql_lower_main
  echoit "Sysbench Run: Creating InnoDB tables"
  sysbench_run innodb test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_innodb_prepare.txt
  ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "CREATE COMPRESSION_DICTIONARY numbers('08566691963-88624912351-16662227201-46648573979-64646226163-77505759394-75470094713-41097360717-15161106334-50535565977');"
  echoit "Compressing and optimizing tables sbtest1 to sbtest5"
  for i in {1..5}; do
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "alter table test.sbtest$i compression='lz4';"
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "optimize table test.sbtest$i;" 1>/dev/null
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "alter table test.sbtest$i modify c varchar(250) column_format compressed with compression_dictionary numbers;"
  done
  
  echoit "Compressing and optimizing tables sbtest6 to sbtest10"
  for i in {6..10}; do
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "alter table test.sbtest$i compression='zlib';"
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "optimize table test.sbtest$i;" 1>/dev/null
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "alter table test.sbtest$i modify c varchar(250) column_format compressed with compression_dictionary numbers;"
  done

  start_mysql_downgrade_main
  mysql_downgrade_datacheck
  echoit "##### END: compression_test #####"
}

function innodb_options_test(){
  local SOCKET=${1:-}

  echoit "##### START: innodb_options_test #####"
  echoit "Creating data for innodb options test"
  start_mysql_lower_main
  echoit "Sysbench Run: Creating InnoDB tables"
  sysbench_run innodb test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  2>&1 | tee $WORKDIR/logs/sysbench_innodb_prepare.txt
 
  if [[ "${MYSQL_EXTRA_OPTIONS}" != *"--innodb_file_per_table=OFF"* ]]; then
     echoit "Creating a table outside data directory"
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "CREATE TABLE test.sbtest1copy (id int(11) NOT NULL AUTO_INCREMENT, k int(11) NOT NULL DEFAULT '0', c char(120) NOT NULL DEFAULT '', pad char(60) NOT NULL DEFAULT '', PRIMARY KEY (id), KEY k_1 (k) ) DATA DIRECTORY = '$WORKDIR' ENGINE=InnoDB;"
     if [ $? -ne 0 ]; then
        echoit "ERR: The table could not be created"
        exit 1
     else
        echoit "The table was created successfully"
     fi
     ${LOWER_BASEDIR}/bin/mysql -uroot --socket=$SOCKET --force -e "insert into test.sbtest1copy select * from test.sbtest1;"
  fi

  start_mysql_downgrade_main
  mysql_downgrade_datacheck
  echoit "##### END: innodb_options_test #####"
}

function startup_check(){
  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${UPPER_BASEDIR}/bin/mysqladmin -uroot -S$1 ping > /dev/null 2>&1; then
      break
    fi  
  done
}

function replication_test(){
  RPL_OPTION="${1:-}"

  echoit "##### START: replication_test ${RPL_OPTION} #####"
  declare SLAVE_ENCRYPT_OPTIONS=""
  rm -rf ${MYSQL_VARDIR}/mysql_master/
  mysql_master_datadir="${MYSQL_VARDIR}/mysql_master"
  PORT_MASTER=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  rm -rf ${MYSQL_VARDIR}/mysql_slave
  mkdir ${MYSQL_VARDIR}/mysql_slave
  mysql_slave_datadir="${MYSQL_VARDIR}/mysql_slave"

  echo "[mysqld]" > ${WORKDIR}/mysql_master.cnf
  echo "datadir=$mysql_master_datadir" >> $WORKDIR/mysql_master.cnf
  echo "port=$PORT_MASTER" >> $WORKDIR/mysql_master.cnf
  echo "innodb_file_per_table" >> $WORKDIR/mysql_master.cnf
  echo "default-storage-engine=InnoDB" >> $WORKDIR/mysql_master.cnf
  echo "server-id=101"  >> $WORKDIR/mysql_master.cnf
  echo "log-bin=mysql-bin"  >> $WORKDIR/mysql_master.cnf
  echo "binlog-format=ROW" >> $WORKDIR/mysql_master.cnf
  if [[ "$RPL_OPTION" == "gtid" ]] || [[ "$RPL_OPTION" == "mts" ]]; then
    echo "gtid-mode=ON" >> $WORKDIR/mysql_master.cnf
    echo "log-slave-updates" >> $WORKDIR/mysql_master.cnf
    echo "enforce-gtid-consistency" >> $WORKDIR/mysql_master.cnf
  fi
  echo "innodb_flush_method=O_DIRECT" >> $WORKDIR/mysql_master.cnf
  echo "core-file" >> $WORKDIR/mysql_master.cnf
  echo "secure-file-priv=" >> $WORKDIR/mysql_master.cnf
  echo "skip-name-resolve" >> $WORKDIR/mysql_master.cnf
  echo "log-error=$WORKDIR/logs/mysql_master.err" >> $WORKDIR/mysql_master.cnf
  echo "socket=$WORKDIR/mysql_master.sock" >> $WORKDIR/mysql_master.cnf
  echo "log-output=none" >> $WORKDIR/mysql_master.cnf

  if [[ "$ENCRYPTION" == 1 ]];then
    if check_for_version $MYSQL_VERSION "8.0.14" ; then
      echo "encrypt_binlog=ON" >> $WORKDIR/mysql_master.cnf
      echo "innodb_encrypt_tables=ON" >> $WORKDIR/mysql_master.cnf
      ENC_VER_SPECIFIC_OPT="--encrypt_binlog=ON --innodb_encrypt_tables=ON"
    else
      echo "binlog_encryption=ON" >> $WORKDIR/mysql_master.cnf
      echo "default_table_encryption=ON" >> $WORKDIR/mysql_master.cnf
      ENC_VER_SPECIFIC_OPT="--encrypt_binlog=ON --default_table_encryption=ON"
    fi
    echo "master_verify_checksum=on" >> $WORKDIR/mysql_master.cnf
    echo "binlog_checksum=crc32" >> $WORKDIR/mysql_master.cnf
    echo "innodb_temp_tablespace_encrypt=ON" >> $WORKDIR/mysql_master.cnf
    echo "encrypt-tmp-files=ON" >> $WORKDIR/mysql_master.cnf
    if check_for_version $MYSQL_VERSION "5.7.23" ; then
      echo "innodb_sys_tablespace_encrypt=ON" >> $WORKDIR/mysql_master.cnf
    fi
    if [[ "$KEYRING_PLUGIN" == "file" ]]; then
      echo "early-plugin-load=keyring_file.so" >> $WORKDIR/mysql_master.cnf
      echo "keyring_file_data=$mysql_master_datadir/keyring" >> $WORKDIR/mysql_master.cnf
      if check_for_version $MYSQL_VERSION "5.7.23" ; then
        INIT_OPT="--early-plugin-load=keyring_file.so --keyring_file_data=$mysql_master_datadir/keyring --innodb_sys_tablespace_encrypt=ON"
      fi

      #Set slave encryption options for keyring file
        SLAVE_ENCRYPT_OPTIONS="${ENC_VER_SPECIFIC_OPT} --master_verify_checksum=ON --binlog_checksum=crc32 --innodb_temp_tablespace_encrypt=ON --encrypt-tmp-files=ON --early-plugin-load=keyring_file.so --keyring_file_data=$mysql_slave_datadir/keyring --innodb_sys_tablespace_encrypt=ON"

    elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
      echo "early-plugin-load=keyring_vault.so" >> $WORKDIR/mysql_master.cnf
      echo "keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf" >> $WORKDIR/mysql_master.cnf
      if check_for_version $MYSQL_VERSION "5.7.23" ; then
        INIT_OPT="--early-plugin-load=keyring_vault.so --keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf --innodb_sys_tablespace_encrypt=ON"
      fi

      #Set slave encryption options for keyring vault
      SLAVE_ENCRYPT_OPTIONS="${ENC_VER_SPECIFIC_OPT} --master_verify_checksum=ON --binlog_checksum=crc32 --innodb_temp_tablespace_encrypt=ON --encrypt-tmp-files=ON --early-plugin-load=keyring_vault.so --keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf --innodb_sys_tablespace_encrypt=ON"
    fi
  fi

  echoit "Initialize and start MySQL master"
  ${LOWER_MID} --datadir=$mysql_master_datadir $INIT_OPT > $WORKDIR/logs/mysql_master.err 2>&1 || exit 1;
  ${LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_master.cnf --basedir=${LOWER_BASEDIR} > $WORKDIR/logs/mysql_master.err 2>&1 &

  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if ${LOWER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/mysql_master.sock ping > /dev/null 2>&1; then
      ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_master.sock -e"drop database if exists test; create database test"
      ${LOWER_BASEDIR}/bin/mysql -uroot -S$WORKDIR/mysql_master.sock -e"CREATE USER rpl_user@'%'  IDENTIFIED BY 'rpl_pass';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%';"
      break
    fi
    if [ $X -eq ${MYSQLD_START_TIMEOUT} ]; then
      echoit "MySQL Master startup failed.."
      grep "ERROR" $WORKDIR/logs/mysql_master.err
      exit 1
      fi
  done

  $LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/mysql_master.sock -u root shutdown

  sleep 10
  cp -a $mysql_master_datadir/* ${MYSQL_VARDIR}/mysql_slave
  rm -rf ${MYSQL_VARDIR}/mysql_slave/auto.cnf

  #Start master
  ${LOWER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_master.cnf --basedir=${LOWER_BASEDIR} > $WORKDIR/logs/mysql_master.err 2>&1 &

  startup_check $WORKDIR/mysql_master.sock

  echoit "Start slave"
  PORT_SLAVE=$[50000 + ( $RANDOM % ( 9999 ) ) ]

  if [ "$RPL_OPTION" == "gtid" ]; then
    ${LOWER_BASEDIR}/bin/mysqld --no-defaults --basedir=${LOWER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  elif [ "$RPL_OPTION" == "mts" ]; then
    ${LOWER_BASEDIR}/bin/mysqld --no-defaults --basedir=${LOWER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --relay-log-info-repository='TABLE' --master-info-repository='TABLE' --slave-parallel-workers=2 --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  else
    ${LOWER_BASEDIR}/bin/mysqld --no-defaults --basedir=${LOWER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  fi

  startup_check $WORKDIR/mysql_slave.sock

  if [ "$RPL_OPTION" == "gtid" -o "$RPL_OPTION" == "mts" ]; then
    echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='rpl_user',MASTER_PASSWORD='rpl_pass',MASTER_AUTO_POSITION=1;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_slave.sock -u root || true
  else
    BIN_FILE=`${LOWER_BASEDIR}/bin/mysql -u root -S $WORKDIR/mysql_master.sock -e "show master status\G" | grep File | awk '{print $2}'`
    BIN_POSITION=`${LOWER_BASEDIR}/bin/mysql -u root -S $WORKDIR/mysql_master.sock -e "show master status\G" | grep Position | awk '{print $2}'`
    if [ -z "$BIN_FILE" -o -z "$BIN_POSITION" ]; then
      echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='rpl_user',MASTER_PASSWORD='rpl_pass',MASTER_LOG_FILE='mysql-bin.000002',MASTER_LOG_POS=154;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_slave.sock -u root || true
    else
      echo "CHANGE MASTER TO MASTER_HOST='127.0.0.1',MASTER_PORT=$PORT_MASTER,MASTER_USER='rpl_user',MASTER_PASSWORD='rpl_pass',MASTER_LOG_FILE='$BIN_FILE',MASTER_LOG_POS=$BIN_POSITION;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_slave.sock -u root || true
    fi
  fi
  echo "START SLAVE;" | $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_slave.sock -u root || true

  echoit "Loading sakila test database"
  $LOWER_BASEDIR/bin/mysql --socket=$WORKDIR/mysql_master.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

  #Check replication status
  SLAVE_IO_STATUS=`${LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/mysql_slave.sock -Bse "show slave status\G" | grep Slave_IO_Running | awk '{ print $2 }'`
  SLAVE_SQL_STATUS=`${LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/mysql_slave.sock -Bse "show slave status\G" | grep -m 1 "Slave_SQL_Running" | awk '{ print $2 }'`

  if [ -z "$SLAVE_IO_STATUS" -o -z "$SLAVE_SQL_STATUS" ] ; then
    echoit "Error : Replication is not running, please check.."
    exit
  fi
  echoit "Replication status : Slave_IO_Running=$SLAVE_IO_STATUS - Slave_SQL_Running=$SLAVE_SQL_STATUS"

  #Upgrade MySQL $mysql_lower_VERSION slave to $MYSQL_UPPER_VERSION for replication test
  echoit "Upgrade MySQL slave"
  SLAVE_ENCRYPT_OPTIONS="${SLAVE_ENCRYPT_OPTIONS/encrypt_binlog/binlog_encryption}"
  SLAVE_ENCRYPT_OPTIONS="${SLAVE_ENCRYPT_OPTIONS/innodb_encrypt_tables/default_table_encryption}"

  $LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/mysql_slave.sock -u root shutdown

  if [ "$RPL_OPTION" == "gtid" ]; then
    ${UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${UPPER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --log-output=none --skip-slave-start ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  elif [ "$RPL_OPTION" == "mts" ]; then
    ${UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${UPPER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --relay-log-info-repository='TABLE' --master-info-repository='TABLE' --slave-parallel-workers=2 --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  else
    ${UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${UPPER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  fi

  startup_check $WORKDIR/mysql_slave.sock

  ${UPPER_BASEDIR}/bin/mysql_upgrade --socket=$WORKDIR/mysql_slave.sock -uroot > $WORKDIR/logs/mysql_rpl_slave_upgrade.log 2>&1

  $LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/mysql_slave.sock -u root shutdown

  if [ "$RPL_OPTION" == "gtid" ]; then
    ${UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${UPPER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  elif [ "$RPL_OPTION" == "mts" ]; then
    ${UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${UPPER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --gtid-mode=ON  --log-slave-updates --enforce-gtid-consistency --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --relay-log-info-repository='TABLE' --master-info-repository='TABLE' --slave-parallel-workers=2 --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  else
    ${UPPER_BASEDIR}/bin/mysqld --no-defaults --basedir=${UPPER_BASEDIR}  --datadir=$mysql_slave_datadir --port=$PORT_SLAVE --innodb_file_per_table --default-storage-engine=InnoDB --binlog-format=ROW --log-bin=mysql-bin --server-id=102 --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --skip-name-resolve --log-error=$WORKDIR/logs/mysql_slave.err --socket=$WORKDIR/mysql_slave.sock --log-output=none ${SLAVE_ENCRYPT_OPTIONS} > $WORKDIR/logs/mysql_slave.err 2>&1 &
  fi

  startup_check $WORKDIR/mysql_slave.sock

  sysbench_run innodb test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$WORKDIR/mysql_master.sock prepare  2>&1 | tee $WORKDIR/logs/rpl_sysbench_prepare.txt

  #Upgrade MySQL $mysql_lower_VERSION master
  echoit "Upgrade MySQL master"

  $LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/mysql_master.sock -u root shutdown

  # Fix config for upper version
  sed -i 's/encrypt_binlog/binlog_encryption/g' $WORKDIR/mysql_master.cnf
  sed -i 's/innodb_encrypt_tables/default_table_encryption/g' $WORKDIR/mysql_master.cnf

  ${UPPER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_master.cnf --basedir=${UPPER_BASEDIR} > $WORKDIR/logs/mysql_master.err 2>&1 &

  startup_check $WORKDIR/mysql_master.sock

  ${UPPER_BASEDIR}/bin/mysql_upgrade --socket=$WORKDIR/mysql_master.sock -uroot > $WORKDIR/logs/mysql_rpl_master_upgrade.log 2>&1

  $LOWER_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/mysql_master.sock -u root shutdown

  ${UPPER_BASEDIR}/bin/mysqld --defaults-file=$WORKDIR/mysql_master.cnf --basedir=${UPPER_BASEDIR} > $WORKDIR/logs/mysql_master.err 2>&1 & 

  startup_check $WORKDIR/mysql_master.sock

  echoit "Waiting for slave to connect to the master"
  sleep 120

  #Check replication status
  SLAVE_IO_STATUS=`${LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/mysql_slave.sock -Bse "show slave status\G" | grep Slave_IO_Running | awk '{ print $2 }'`
  SLAVE_SQL_STATUS=`${LOWER_BASEDIR}/bin/mysql -uroot -S${WORKDIR}/mysql_slave.sock -Bse "show slave status\G" | grep -m 1 "Slave_SQL_Running" | awk '{ print $2 }'`

  if [ -z "$SLAVE_IO_STATUS" -o -z "$SLAVE_SQL_STATUS" ] ; then
    echoit "Error : Replication is not running, please check.."
    exit
  fi

  echoit "Replication status after master upgrade : Slave_IO_Running=$SLAVE_IO_STATUS - Slave_SQL_Running=$SLAVE_SQL_STATUS"
  ${UPPER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/mysql_master.sock shutdown
  ${UPPER_BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/mysql_slave.sock shutdown
  echoit "##### END: replication_test ${RPL_OPTION} #####"
}

#Run tests
for i in "${TC_ARRAY[@]}"; do
  case "$i" in
    partition_test )
    partition_test "$WORKDIR/mysql_lower.sock"
    ;;
    non_partition_test )
    non_partition_test "$WORKDIR/mysql_lower.sock"
    ;;
    compression_test )
    compression_test "$WORKDIR/mysql_lower.sock"
    ;;
    innodb_options_test )
    innodb_options_test "$WORKDIR/mysql_lower.sock"
    ;;
    replication_test_gtid )
    replication_test "gtid"
    ;;
    replication_test_mts )
    replication_test "mts"
    ;;
    replication_test )
    replication_test
    ;;
    all )
    non_partition_test "$WORKDIR/mysql_lower.sock"
    partition_test "$WORKDIR/mysql_lower.sock"
    compression_test "$WORKDIR/mysql_lower.sock"
    innodb_options_test "$WORKDIR/mysql_lower.sock"
    replication_test "gtid"
    replication_test "mts"
    replication_test
    ;;
  esac
done

echoit "MySQL upgrade test completed successfully"
