#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test replication features

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
  echo "  -w, --workdir                     Specify work directory"
  echo "  -s, --storage-engine              Specify mysql server storage engine"
  echo "  -b, --build-number                Specify work build directory"
  echo "  -k, --keyring-plugin=[file|vault] Specify which keyring plugin to use(default keyring-file)"
  echo "  -t, --testcase=<testcases|all>    Run only following comma-separated list of testcases"
  echo "                                      node1_master_test"
  echo "                                      node1_slave_test"
  echo "                                      node2_slave_test"
  echo "                                      pxc_master_slave_shuffle_test"
  echo "                                      pxc_msr_test"
  echo "                                      pxc_mtr_test"
  echo "                                    If you specify 'all', the script will execute all testcases"
  echo ""
  echo "  -e, --with-encryption              Run the script with encryption feature"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:s:k:t:eh --longoptions=workdir:,storage-engine:,build-number:,keyring-plugin:,testcase:,with-encryption,help \
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
    export WORKDIR="$2"
    if [[ ! -d "$WORKDIR" ]]; then
      echo "ERROR: Workdir ($WORKDIR) directory does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -b | --build-number )
    export BUILD_NUMBER="$2"
    shift 2
    ;;
    -s | --storage-engine )
    export ENGINE="$2"
    if [ "$ENGINE" != "innodb" ] && [ "$ENGINE" != "rocksdb" ] && [ "$ENGINE" != "tokudb" ]; then
      echo "ERROR: Invalid --storage-engine passed:"
      echo "  Please choose any of these storage engine options: innodb, rocksdb, tokudb"
      exit 1
    fi
    shift 2
    ;;
    -k | --keyring-plugin )
    export KEYRING_PLUGIN="$2"
    shift 2
    if [[ "$KEYRING_PLUGIN" != "file" ]] && [[ "$KEYRING_PLUGIN" != "vault" ]] ; then
      echo "ERROR: Invalid --keyring-plugin passed:"
      echo "  Please choose any of these keyring-plugin options: 'file' or 'vault'"
      exit 1
    fi
    ;;
    -t | --testcase )
    export TESTCASE="$2"
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
  export WORKDIR=${PWD}
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  export BUILD_NUMBER="100"
fi

if [[ -z "$KEYRING_PLUGIN" ]]; then
  export KEYRING_PLUGIN="file"
fi

if [[ ! -z "$TESTCASE" ]]; then
  IFS=', ' read -r -a TC_ARRAY <<< "$TESTCASE"
else
  TC_ARRAY=(all)
fi

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
PS_START_TIMEOUT=60

cd $WORKDIR

if [ -z ${SDURATION} ]; then
  SDURATION=30
fi

if [ -z ${SST_METHOD} ]; then
  SST_METHOD=rsync
fi

if [ -z ${TSIZE} ]; then
  TSIZE=500
fi

if [ -z ${NUMT} ]; then
  NUMT=16
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=16
fi

if [ -z "$ENGINE" ]; then
  ENGINE="INNODB"
fi


WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/ps_async_test.log; fi
}
if [ "$ENGINE" == "rocksdb" ]; then
  if [[ ! -e $(which mysqldbcompare 2> /dev/null) ]] ;then
    echo "ERROR! mysql utilities are currently not installed. Please install mysql utilities. Terminating"
    exit 1
  fi
fi

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
  export PATH="$ROOT_FS/$PSBASE/bin:$PATH"
fi
PS_BASEDIR="${ROOT_FS}/$PSBASE"

#Check Percona Toolkit binary tar ball
PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
if [ ! -z $PT_TAR ];then
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
else
  wget https://www.percona.com/downloads/percona-toolkit/2.2.16/tarball/percona-toolkit-2.2.16.tar.gz
  PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
fi

#Check sysbench
if [[ ! -e `which sysbench` ]];then
    echoit "Sysbench not found"
    exit 1
fi
echoit "Note: Using sysbench at $(which sysbench)"

#sysbench command should compatible with versions 0.5 and 1.0
sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-storage-engine=$ENGINE --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "insert_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=30 --max-requests=1870000000 --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-storage-engine=$ENGINE --mysql-db=$DB --mysql-user=root  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    elif [ "$TEST_TYPE" == "insert_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=30 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}


MYSQL_VERSION=$(${PS_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${PS_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PS_BASEDIR}"
else
  MID="${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure  ${MYEXTRA_KEYRING} --basedir=${PS_BASEDIR}"
fi

echoit "Setting PS Port"
ADDR="127.0.0.1"
RPORT=$(( (RANDOM%21 + 10)*1000 ))
LADDR="$ADDR:$(( RPORT + 8 ))"

SUSER=root
SPASS=

#Check command failure
check_cmd(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echoit "ERROR: $ERROR_MSG. Terminating!"; exit 1; fi
}

#Async replication test
function async_rpl_test(){
  MYEXTRA_CHECK=$1
  function ps_start(){
    INTANCES="$1"
    if [ -z $INTANCES ];then
      INTANCES=1
    fi
    for i in `seq 1 $INTANCES`;do
      STARTUP_OPTION="$2"
      RBASE1="$((RPORT + ( 100 * $i )))"
      if ps -ef | grep  "\--port=${RBASE1}"  | grep -qv grep  ; then
        echoit "INFO! Another mysqld server running on port: ${RBASE1}. Using different port"
        RBASE1="$(( (RPORT + ( 100 * $i )) + 10 ))"
      fi
      echoit "Starting independent PS node${i}.."
      node="${WORKDIR}/psnode${i}"
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
      if [ "$ENGINE" == "innodb" ]; then
        echo "default-storage-engine=INNODB" >> ${PS_BASEDIR}/n${i}.cnf
      elif [ "$ENGINE" == "rocksdb" ]; then
        echo "plugin-load-add=rocksdb=ha_rocksdb.so" >> ${PS_BASEDIR}/n${i}.cnf
        echo "init-file=${SCRIPT_PWD}/MyRocks.sql" >> ${PS_BASEDIR}/n${i}.cnf
        echo "default-storage-engine=ROCKSDB" >> ${PS_BASEDIR}/n${i}.cnf
        echo "rocksdb-flush-log-at-trx-commit=2" >> ${PS_BASEDIR}/n${i}.cnf
        echo "rocksdb-wal-recovery-mode=2" >> ${PS_BASEDIR}/n${i}.cnf
      elif [ "$ENGINE" == "tokudb" ]; then
        echo "plugin-load-add=tokudb=ha_tokudb.so" >> ${PS_BASEDIR}/n${i}.cnf
        echo "tokudb-check-jemalloc=0" >> ${PS_BASEDIR}/n${i}.cnf
        echo "init-file=${SCRIPT_PWD}/TokuDB.sql" >> ${PS_BASEDIR}/n${i}.cnf
        echo "default-storage-engine=TokuDB" >> ${PS_BASEDIR}/n${i}.cnf
      fi
      if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
        echo "gtid-mode=ON" >> ${PS_BASEDIR}/n${i}.cnf
        echo "enforce-gtid-consistency" >> ${PS_BASEDIR}/n${i}.cnf
      fi
      if [[ "$ENCRYPTION" == 1 ]];then
        echo "encrypt_binlog" >> ${PS_BASEDIR}/n${i}.cnf
        echo "master_verify_checksum=on" >> ${PS_BASEDIR}/n${i}.cnf
        echo "binlog_checksum=crc32" >> ${PS_BASEDIR}/n${i}.cnf
        echo "innodb_temp_tablespace_encrypt=ON" >> ${PS_BASEDIR}/n${i}.cnf
        echo "encrypt-tmp-files=ON" >> ${PS_BASEDIR}/n${i}.cnf
        echo "innodb_encrypt_tables=ON" >> ${PS_BASEDIR}/n${i}.cnf
  	    if [[ "$KEYRING_PLUGIN" == "file" ]]; then
          echo "early-plugin-load=keyring_file.so" >> ${PS_BASEDIR}/n${i}.cnf
          echo "keyring_file_data=$node/keyring" >> ${PS_BASEDIR}/n${i}.cnf
          echo "innodb_sys_tablespace_encrypt=ON" >> ${PS_BASEDIR}/n${i}.cnf
  	    elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
          echo "early-plugin-load=keyring_vault.so" >> ${PS_BASEDIR}/n${i}.cnf
          echo "keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf" >> ${PS_BASEDIR}/n${i}.cnf
          echo "innodb_sys_tablespace_encrypt=ON" >> ${PS_BASEDIR}/n${i}.cnf
        fi
      fi

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

  function run_pt_table_checksum(){
    DATABASES=$1
    SOCKET=$2
    pt-table-checksum S=$SOCKET,u=root -d $DATABASES --recursion-method hosts --no-check-binlog-format
    check_cmd $?
  }
  function run_mysqldbcompare(){
    DATABASES=$1
    MASTER_SOCKET=$2
    SLAVE_SOCKET=$3
    mysqldbcompare --server1=root@localhost:$MASTER_SOCKET --server2=root@localhost:$SLAVE_SOCKET $DATABASES --changes-for=server2  --difftype=sql
    check_cmd $?
  }

  function invoke_slave(){
    MASTER_SOCKET=$1
    SLAVE_SOCKET=$2
    REPL_STRING=$3
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "show master logs" | awk '{print $1}' | tail -1`
    MASTER_HOST_PORT=`${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "select @@port"`
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_AUTO_POSITION=1 $REPL_STRING"
    else
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4 $REPL_STRING"
    fi
  }

  function slave_startup_check(){
    SOCKET_FILE=$1
    SLAVE_STATUS=$2
    ERROR_LOG=$3
    MSR_SLAVE_STATUS=$4
    SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" > $SLAVE_STATUS
        echoit "Slave is not started yet. Please check error log and slave status : $ERROR_LOG, $SLAVE_STATUS"
        exit 1
      fi
      sleep 1;
    done
  }

  function slave_sync_check(){
    SOCKET_FILE=$1
    SLAVE_STATUS=$2
    ERROR_LOG=$3
    SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echoit "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi
      let COUNTER=COUNTER+1
      sleep 5
      if [ $COUNTER -eq 300 ]; then
        echoit "WARNING! Seems slave second behind master is not moving forward, skipping slave sync status check"
        break
      fi
    done
  }

  function async_sysbench_rw_run(){
    MASTER_DB=$1
    SLAVE_DB=$2
    MASTER_SOCKET=$3
    SLAVE_SOCKET=$4
    #OLTP RW run on master
    echoit "OLTP RW run on master (Database: $MASTER_DB)"
    sysbench_run oltp $MASTER_DB
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$MASTER_SOCKET run  > $WORKDIR/logs/sysbench_master_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench oltp read/write run on master ($MASTER_SOCKET)"

    #OLTP RW run on slave
    echoit "OLTP RW run on slave (Database: $SLAVE_DB)"
    sysbench_run oltp $SLAVE_DB
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SLAVE_SOCKET run  > $WORKDIR/logs/sysbench_slave_rw.log 2>&1
    check_cmd $? "Failed to execute sysbench oltp read/write run on slave($SLAVE_SOCKET)"
  }

  function async_sysbench_insert_run(){
    DATABASE_NAME=$1
    SOCKET=$2
    echoit "Sysbench insert run (Database: $DATABASE_NAME)"
    sysbench_run insert_data $DATABASE_NAME
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET run  > $WORKDIR/logs/sysbench_insert.log 2>&1
    check_cmd $? "Failed to execute sysbench insert run ($SOCKET)"
  }

  function async_sysbench_load(){
    DATABASE_NAME=$1
    SOCKET=$2
    echoit "Sysbench Run: Prepare stage (Database: $DATABASE_NAME)"
    sysbench_run load_data $DATABASE_NAME
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  > $WORKDIR/logs/sysbench_prepare.txt 2>&1
    check_cmd $? "Failed to execute sysbench prepare stage ($SOCKET)"
  }

  function gt_test_run(){
    DATABASE_NAME=$1
    SOCKET=$2
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "CREATE TABLESPACE ${DATABASE_NAME}_gen_ts1 ADD DATAFILE '${DATABASE_NAME}_gen_ts1.ibd' ENCRYPTION='Y'"  2>&1
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "CREATE TABLE ${DATABASE_NAME}_gen_ts_tb1(id int auto_increment, str varchar(32), primary key(id)) TABLESPACE ${DATABASE_NAME}_gen_ts1" 2>&1
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "CREATE TABLE ${DATABASE_NAME}_sys_ts_tb1(id int auto_increment, str varchar(32), primary key(id)) TABLESPACE=innodb_system ENCRYPTION='Y'" 2>&1
    NUM_ROWS=$(shuf -i 100-500 -n 1)
    for i in `seq 1 $NUM_ROWS`; do
      STRING=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "INSERT INTO ${DATABASE_NAME}_gen_ts_tb1 (str) VALUES ('${STRING}')"
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "INSERT INTO ${DATABASE_NAME}_sys_ts_tb1 (str) VALUES ('${STRING}')"
    done
  }

  function master_slave_test(){
    echoit "******************** $MYEXTRA_CHECK master slave test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 2

    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"

    echoit "Checking slave startup"
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists sbtest_ps_slave;create database sbtest_ps_slave;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
    async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"
    async_sysbench_load sbtest_ps_slave "/tmp/ps2.sock"

    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave "/tmp/ps1.sock" "/tmp/ps2.sock"
    sleep 5

    if [ "$ENCRYPTION" == 1 ];then
      echoit "Running general tablespace encryption test run"
      gt_test_run sbtest_ps_master "/tmp/ps1.sock"
      gt_test_run sbtest_ps_slave "/tmp/ps2.sock"
    fi
    sleep 5

    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    sleep 10
    echoit "1. PS master slave: Checksum result."
    if [ "$ENGINE" == "ROCKSDB" ]; then
      run_mysqldbcompare "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps2.sock"
    else
      run_pt_table_checksum "sbtest_ps_master" "/tmp/ps1.sock"
    fi
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }

  function master_multi_slave_test(){
    echoit "********************$MYEXTRA_CHECK master multiple slave test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 4

    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps1.sock" "/tmp/ps3.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps1.sock" "/tmp/ps4.sock" ";START SLAVE;"

    echoit "Checking slave startup"
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    slave_startup_check "/tmp/ps3.sock" "$WORKDIR/logs/slave_status_psnode3.log" "$WORKDIR/logs/psnode3.err"
    slave_startup_check "/tmp/ps4.sock" "$WORKDIR/logs/slave_status_psnode4.log" "$WORKDIR/logs/psnode4.err"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"drop database if exists sbtest_ps_slave_1;create database sbtest_ps_slave_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"drop database if exists sbtest_ps_slave_2;create database sbtest_ps_slave_2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps4.sock -e"drop database if exists sbtest_ps_slave_3;create database sbtest_ps_slave_3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
    async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"
    async_sysbench_load sbtest_ps_slave_1 "/tmp/ps2.sock"
    async_sysbench_load sbtest_ps_slave_2 "/tmp/ps3.sock"
    async_sysbench_load sbtest_ps_slave_3 "/tmp/ps4.sock"

    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave_1 "/tmp/ps1.sock" "/tmp/ps2.sock"
    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave_2 "/tmp/ps1.sock" "/tmp/ps3.sock"
    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave_3 "/tmp/ps1.sock" "/tmp/ps4.sock"

    async_sysbench_insert_run sbtest_ps_master "/tmp/ps1.sock"
    async_sysbench_insert_run sbtest_ps_slave_1 "/tmp/ps2.sock"
    async_sysbench_insert_run sbtest_ps_slave_2 "/tmp/ps3.sock"
    async_sysbench_insert_run sbtest_ps_slave_3 "/tmp/ps4.sock"
    sleep 5

    if [ "$ENCRYPTION" == 1 ];then
      echoit "Running general tablespace encryption test run"
      gt_test_run sbtest_ps_master "/tmp/ps1.sock"
      gt_test_run sbtest_ps_slave_1 "/tmp/ps2.sock"
      gt_test_run sbtest_ps_slave_2 "/tmp/ps3.sock"
      gt_test_run sbtest_ps_slave_3 "/tmp/ps4.sock"
    fi
    sleep 5

    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    slave_sync_check "/tmp/ps3.sock" "$WORKDIR/logs/slave_status_psnode3.log" "$WORKDIR/logs/psnode3.err"
    slave_sync_check "/tmp/ps4.sock" "$WORKDIR/logs/slave_status_psnode4.log" "$WORKDIR/logs/psnode4.err"
    sleep 10
    echoit "2. PS master multi slave: Checksum result."
    if [ "$ENGINE" == "ROCKSDB" ]; then
      run_mysqldbcompare "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps3.sock"
      run_mysqldbcompare "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps4.sock"
    else
      run_pt_table_checksum "sbtest_ps_master" "/tmp/ps1.sock"
    fi
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps4.sock -u root shutdown
  }

  function master_master_test(){
    echoit "********************$MYEXTRA_CHECK master master test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 2

    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps2.sock" "/tmp/ps1.sock" ";START SLAVE;"

    echoit "Checking slave startup"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"drop database if exists sbtest_ps_master_1;create database sbtest_ps_master_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"drop database if exists sbtest_ps_master_2;create database sbtest_ps_master_2;"

    async_sysbench_load sbtest_ps_master_1 "/tmp/ps1.sock"
    async_sysbench_load sbtest_ps_master_2 "/tmp/ps2.sock"

    async_sysbench_rw_run sbtest_ps_master_1 sbtest_ps_master_2 "/tmp/ps1.sock" "/tmp/ps2.sock"

    async_sysbench_insert_run sbtest_ps_master_1 "/tmp/ps1.sock"
    async_sysbench_insert_run sbtest_ps_master_2 "/tmp/ps2.sock"
    sleep 5

    if [ "$ENCRYPTION" == 1 ];then
      echoit "Running general tablespace encryption test run"
      gt_test_run sbtest_ps_master_1 "/tmp/ps1.sock"
      gt_test_run sbtest_ps_master_2 "/tmp/ps2.sock"
    fi
    sleep 5

    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"
    slave_sync_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"

    sleep 10
    echoit "3. PS master master: Checksum result."
    if [ "$ENGINE" == "ROCKSDB" ]; then
      run_mysqldbcompare "sbtest_ps_master_1" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "sbtest_ps_master_2" "/tmp/ps1.sock" "/tmp/ps2.sock"
    else
      run_pt_table_checksum "sbtest_ps_master_1,sbtest_ps_master_2" "/tmp/ps1.sock"
    fi
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }

  function msr_test(){
    echo "********************$MYEXTRA_CHECK multi source replication test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 4
    echo "Sysbench Run for replication master master test : Prepare stage"
    invoke_slave "/tmp/ps2.sock" "/tmp/ps1.sock" "FOR CHANNEL 'master1';"
    invoke_slave "/tmp/ps3.sock" "/tmp/ps1.sock" "FOR CHANNEL 'master2';"
    invoke_slave "/tmp/ps4.sock" "/tmp/ps1.sock" "FOR CHANNEL 'master3';"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"START SLAVE;"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err" "for channel 'master1'"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err" "for channel 'master2'"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err" "for channel 'master3'"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists msr_db_master1;create database msr_db_master1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e "drop database if exists msr_db_master2;create database msr_db_master2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps4.sock -e "drop database if exists msr_db_master3;create database msr_db_master3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists msr_db_slave;create database msr_db_slave;"
    sleep 5
    # Sysbench dataload for MSR test
    async_sysbench_load msr_db_master1 "/tmp/ps2.sock"
    async_sysbench_load msr_db_master2 "/tmp/ps3.sock"
    async_sysbench_load msr_db_master3 "/tmp/ps4.sock"

    sysbench_run oltp msr_db_master1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_ps_channel1_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (/tmp/ps2.sock)"
    sysbench_run oltp msr_db_master2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock  run  > $WORKDIR/logs/sysbench_ps_channel2_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (/tmp/ps3.sock)"
    sysbench_run oltp msr_db_master3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps4.sock  run  > $WORKDIR/logs/sysbench_ps_channel3_rw.log 2>&1
    check_cmd $? "Failed to execute sysbench read/write run (/tmp/ps4.sock)"

    async_sysbench_insert_run msr_db_master1 "/tmp/ps2.sock"
    async_sysbench_insert_run msr_db_master2 "/tmp/ps3.sock"
    async_sysbench_insert_run msr_db_master3 "/tmp/ps4.sock"
	sleep 5

    if [ "$ENCRYPTION" == 1 ];then
      echoit "Running general tablespace encryption test run"
      gt_test_run msr_db_master1 "/tmp/ps2.sock"
      gt_test_run msr_db_master2 "/tmp/ps3.sock"
      gt_test_run msr_db_master3 "/tmp/ps4.sock"
    fi

    sleep 10
    SB_CHANNEL1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master1'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master2'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL3=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    if ! [[ "$SB_CHANNEL1" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL2" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
      exit 1
    fi

    while [ $SB_CHANNEL3 -gt 0 ]; do
      SB_CHANNEL3=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
        echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
        exit 1
      fi
      sleep 5
    done
    sleep 10
    echoit "4. multi source replication: Checksum result."

    if [ "$ENGINE" == "ROCKSDB" ]; then
      echoit "Checksum for msr_db_master1 database"
      run_mysqldbcompare "msr_db_master1" "/tmp/ps2.sock" "/tmp/ps1.sock"
      echoit "Checksum for msr_db_master2 database"
      run_mysqldbcompare "msr_db_master2" "/tmp/ps3.sock" "/tmp/ps1.sock"
      echoit "Checksum for msr_db_master3 database"
      run_mysqldbcompare "msr_db_master3" "/tmp/ps4.sock" "/tmp/ps1.sock"
    else
      echoit "Checksum for msr_db_master1 database"
      run_pt_table_checksum "msr_db_master1" "/tmp/ps2.sock"
      echoit "Checksum for msr_db_master2 database"
      run_pt_table_checksum "msr_db_master2" "/tmp/ps3.sock"
      echoit "Checksum for msr_db_master3 database"
      run_pt_table_checksum "msr_db_master3" "/tmp/ps4.sock"
    fi

    #Shutdown PS servers for MSR test
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps4.sock -u root shutdown
  }

  function mtr_test(){
    echo "********************$MYEXTRA_CHECK multi thread replication test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 2 "--slave-parallel-workers=5"

    echo "Sysbench Run for replication master master test : Prepare stage"
    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps2.sock" "/tmp/ps1.sock" ";START SLAVE;"

    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_1;create database mtr_db_ps1_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_2;create database mtr_db_ps1_2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_3;create database mtr_db_ps1_3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_4;create database mtr_db_ps1_4;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_5;create database mtr_db_ps1_5;"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_1;create database mtr_db_ps2_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_2;create database mtr_db_ps2_2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_3;create database mtr_db_ps2_3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_4;create database mtr_db_ps2_4;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_5;create database mtr_db_ps2_5;"

    sleep 5
    # Sysbench dataload for MTR test
    echoit "Sysbench dataload for MTR test"
    async_sysbench_load mtr_db_ps1_1 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_2 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_3 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_4 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_5 "/tmp/ps1.sock"

    async_sysbench_load mtr_db_ps2_1 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_2 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_3 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_4 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_5 "/tmp/ps2.sock"

    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_ps1_1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_1_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps1_1 ,socket : /tmp/ps1.sock)"
    sysbench_run oltp mtr_db_ps1_2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_2_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps1_2 ,socket : /tmp/ps1.sock)"
    sysbench_run oltp mtr_db_ps1_3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_3_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps1_3 ,socket : /tmp/ps1.sock)"
    sysbench_run oltp mtr_db_ps1_4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_4_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps1_4 ,socket : /tmp/ps1.sock)"
    sysbench_run oltp mtr_db_ps1_5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_5_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps1_5 ,socket : /tmp/ps1.sock)"
    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_ps2_1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_1_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps2_1 ,socket : /tmp/ps2.sock)"
    sysbench_run oltp mtr_db_ps2_2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_2_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps2_2 ,socket : /tmp/ps2.sock)"
    sysbench_run oltp mtr_db_ps2_3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_3_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps2_3 ,socket : /tmp/ps2.sock)"
    sysbench_run oltp mtr_db_ps2_4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_4_rw.log 2>&1 &
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps2_4 ,socket : /tmp/ps2.sock)"
    sysbench_run oltp mtr_db_ps2_5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_5_rw.log 2>&1
    check_cmd $? "Failed to execute sysbench read/write run (DB : mtr_db_ps2_5 ,socket : /tmp/ps2.sock)"

    # Sysbench data insert run for MTR test
    echoit "Sysbench data insert run for MTR test"
    async_sysbench_insert_run mtr_db_ps1_1 "/tmp/ps1.sock"
    async_sysbench_insert_run mtr_db_ps1_2 "/tmp/ps1.sock"
    async_sysbench_insert_run mtr_db_ps1_3 "/tmp/ps1.sock"
    async_sysbench_insert_run mtr_db_ps1_4 "/tmp/ps1.sock"
    async_sysbench_insert_run mtr_db_ps1_5 "/tmp/ps1.sock"

    async_sysbench_insert_run mtr_db_ps2_1 "/tmp/ps2.sock"
    async_sysbench_insert_run mtr_db_ps2_2 "/tmp/ps2.sock"
    async_sysbench_insert_run mtr_db_ps2_3 "/tmp/ps2.sock"
    async_sysbench_insert_run mtr_db_ps2_4 "/tmp/ps2.sock"
    async_sysbench_insert_run mtr_db_ps2_5 "/tmp/ps2.sock"
    sleep 5

    if [ "$ENCRYPTION" == 1 ];then
      echoit "Running general tablespace encryption test run"
      gt_test_run mtr_db_ps1_1 "/tmp/ps1.sock"
      gt_test_run mtr_db_ps2_1 "/tmp/ps2.sock"
    fi

    sleep 10
    SB_PS_1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_PS_2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    while [ $SB_PS_1 -gt 0 ]; do
      SB_PS_1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PS_1" =~ ^[0-9]+$ ]]; then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode2.err,  $WORKDIR/logs/slave_status_psnode2.log"
        exit 1
      fi
      sleep 5
    done

    while [ $SB_PS_2 -gt 0 ]; do
      SB_PS_2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PS_2" =~ ^[0-9]+$ ]]; then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi
      sleep 5
    done

    sleep 10
    echoit "5. multi thread replication: Checksum result."
    if [ "$ENGINE" == "ROCKSDB" ]; then
      run_mysqldbcompare "mtr_db_ps1_1" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps1_2" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps1_3" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps1_4" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps1_5" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps2_1" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps2_2" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps2_3" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps2_4" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqldbcompare "mtr_db_ps2_5" "/tmp/ps1.sock" "/tmp/ps2.sock"
    else
      run_pt_table_checksum "mtr_db_ps1_1,mtr_db_ps1_2,mtr_db_ps1_3,mtr_db_ps1_4,mtr_db_ps1_5,mtr_db_ps2_1,mtr_db_ps2_2,mtr_db_ps2_3,mtr_db_ps2_4,mtr_db_ps2_5"  "/tmp/ps1.sock"
    fi

    #Shutdown PS servers
    echoit "Shuttingdown PS servers"
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }

  if [[ ! " ${TC_ARRAY[@]} " =~ " all " ]]; then
    for i in "${TC_ARRAY[@]}"; do
      if [[ "$i" == "master_slave_test" ]]; then
  	    master_slave_test
  	  elif [[ "$i" == "master_multi_slave_test" ]]; then
  	    master_multi_slave_test
  	  elif [[ "$i" == "master_master_test" ]]; then
  	    master_master_test
  	  elif [[ "$i" == "msr_test" ]]; then
        if check_for_version $MYSQL_VERSION "5.7.0" ; then 
          msr_test
        fi
      elif [[ "$i" == "mtr_test" ]]; then
  	   mtr_test
      fi
    done
  else
    master_slave_test
    master_multi_slave_test
    master_master_test
    msr_test
    if check_for_version $MYSQL_VERSION "5.7.0" ; then 
      msr_test
    fi
    mtr_test
  fi  
}

async_rpl_test
async_rpl_test GTID
