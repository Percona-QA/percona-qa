#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test replication features
# Master-Slave replication test
# Master-Master replication test
# Multi Source replication test
# Multi thread replication test
# Group replication test
# Master Slave replication using XtraBackup test

# Bash internal configuration
#
set -o nounset    # no undefined variables

# Global variables
declare ADDR="127.0.0.1"
declare PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
declare -i RPORT=$(( (RANDOM%21 + 10)*1000 ))
declare LADDR="$ADDR:$(( RPORT + 8 ))"
declare SUSER=root
declare SPASS=""
declare SBENCH="sysbench"
declare SCRIPT_PWD=$(cd `dirname $0` && pwd)
declare -i PS_START_TIMEOUT=60
declare WORKDIR=""
declare BUILD_NUMBER
declare ENGINE=""
declare KEYRING_PLUGIN=""
declare TESTCASE=""
declare ENCRYPTION=""
declare TC_ARRAY=""
declare ROOT_FS=""
declare SDURATION=""
declare TSIZE=""
declare NUMT=""
declare TCOUNT=""
declare PS_TAR=""
declare PSBASE=""
declare PS_BASEDIR=""
declare PT_TAR=""
declare PTBASE=""
declare MID=""
declare SYSBENCH_OPTIONS=""

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
  echo "  -w, --workdir                     Specify work directory"
  echo "  -s, --storage-engine              Specify mysql server storage engine"
  echo "  -b, --build-number                Specify work build directory"
  echo "  -k, --keyring-plugin=[file|vault] Specify which keyring plugin to use(default keyring-file)"
  echo "  -t, --testcase=<testcases|all>    Run only following comma-separated list of testcases"
  echo "                                      master_slave_test"
  echo "                                      master_multi_slave_test"
  echo "                                      master_master_test"
  echo "                                      msr_test"
  echo "                                      mtr_test"
  echo "                                      mgr_test"
  echo "                                      xb_master_slave_test"
  echo "                                    If you specify 'all', the script will execute all testcases"
  echo ""
  echo "  -e, --with-encryption             Run the script with encryption feature"
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
    -s | --storage-engine )
    ENGINE="$2"
    if [ "$ENGINE" != "innodb" ] && [ "$ENGINE" != "rocksdb" ] && [ "$ENGINE" != "tokudb" ]; then
      echo "ERROR: Invalid --storage-engine passed:"
      echo "  Please choose any of these storage engine options: innodb, rocksdb, tokudb"
      exit 1
    fi
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

if [[ -z "$KEYRING_PLUGIN" ]]; then
  KEYRING_PLUGIN="file"
fi

if [[ ! -z "$TESTCASE" ]]; then
  IFS=', ' read -r -a TC_ARRAY <<< "$TESTCASE"
else
  TC_ARRAY=(all)
fi

ROOT_FS=$WORKDIR
cd $WORKDIR

if [ -z ${SDURATION} ]; then
  SDURATION=5
fi

if [ -z ${TSIZE} ]; then
  TSIZE=50
fi

if [ -z ${NUMT} ]; then
  NUMT=4
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=4
fi

if [ -z "$ENGINE" ]; then
  ENGINE="innodb"
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/ps_async_test.log; fi
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

#Kill existing mysqld process
ps -ef | grep 'ps[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
ps -ef | grep 'bkpslave.sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

cleanup(){
  cp -f ${PS_BASEDIR}/*.cnf $WORKDIR/logs
  if [ -d "$WORKDIR/vault" ]; then
    rm -f $WORKDIR/vault/vault
    cp -af $WORKDIR/vault $WORKDIR/logs
  fi
  tar czf $ROOT_FS/results-${BUILD_NUMBER}${TEST_DESCRIPTION:-}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

#Check PS binary tar ball
PS_TAR=`ls -1td ?ercona-?erver* | grep ".tar" | head -n1`
if [ ! -z $PS_TAR ];then
  tar -xzf $PS_TAR
  PSBASE=`ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1`
  if [[ -z $PSBASE ]]; then
    echo "ERROR! Could not find Percona Server directory. Terminating!"
    exit 1
  else
    export PATH="$ROOT_FS/$PSBASE/bin:$PATH"
  fi
else
  PSBASE=`ls -1td ?ercona-?erver* 2>/dev/null | grep -v ".tar" | head -n1`
  if [[ -z $PSBASE ]] ; then
    echoit "ERROR! Could not find Percona Server directory. Terminating!"
    exit 1
  else
    export PATH="$ROOT_FS/$PSBASE/bin:$PATH"
  fi
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

function check_xb_dir(){
  #Check Percona XtraBackup binary tar ball
  pushd $ROOT_FS
  PXB_TAR=`ls -1td ?ercona-?trabackup* | grep ".tar" | head -n1`
  if [ ! -z $PXB_TAR ];then
    tar -xzf $PXB_TAR
    PXBBASE=`ls -1td ?ercona-?trabackup* | grep -v ".tar" | head -n1`
    export PATH="$ROOT_FS/$PXBBASE/bin:$PATH"
  else
    PXB_TAR=`ls -1td ?ercona-?trabackup* | grep ".tar" | head -n1`
    tar -xzf $PXB_TAR
    PXBBASE=`ls -1td ?ercona-?trabackup* | grep -v ".tar" | head -n1`
    export PATH="$ROOT_FS/$PXBBASE/bin:$PATH"
  fi
  PXBBASE="$ROOT_FS/$PXBBASE"
  popd
}
  
#Check sysbench
if [[ ! -e `which sysbench` ]];then
  echoit "Sysbench not found"
  exit 1
fi
echoit "Note: Using sysbench at $(which sysbench)"

#sysbench command should compatible with versions 0.5 and 1.0
sysbench_run(){
  local TEST_TYPE="${1:-}"
  local DB="${2:-}"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-storage-engine=$ENGINE --mysql-user=test_user --mysql-password=test  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=test_user --mysql-password=test  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "insert_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=10 --max-requests=1870000000 --mysql-db=$DB --mysql-user=test_user --mysql-password=test  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-storage-engine=$ENGINE --mysql-db=$DB --mysql-user=test_user --mysql-password=test  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=test_user --mysql-password=test  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    elif [ "$TEST_TYPE" == "insert_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=test_user --mysql-password=test  --threads=$NUMT --time=10 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}


declare MYSQL_VERSION=$(${PS_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe ' Ver [0-9]\.[0-9][\.0-9]*'|sed 's/ Ver //')
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${PS_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PS_BASEDIR}"
else
  if [[ -z $ENCRYPTION ]]; then
    MID="${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PS_BASEDIR}"
  else
    if [[ "$KEYRING_PLUGIN" == "file" ]]; then
      MID="${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --early-plugin-load=keyring_file.so --keyring_file_data=keyring --basedir=${PS_BASEDIR} --innodb_sys_tablespace_encrypt=ON"
    elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
      MID="${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --early-plugin-load=keyring_vault.so --keyring_vault_config=$WORKDIR/vault/keyring_vault_ps.cnf --basedir=${PS_BASEDIR} --innodb_sys_tablespace_encrypt=ON"
    fi
  fi
fi

#Check command failure
check_cmd(){
  local MPID=${1:-}
  local ERROR_MSG=${2:-}
  if [ ${MPID} -ne 0 ]; then echoit "ERROR: $ERROR_MSG. Terminating!"; exit 1; fi
}

#Async replication test
function async_rpl_test(){
  local MYEXTRA_CHECK="${1:-}"
  function ps_start(){
    local INTANCES="${1:-}"
    local EXTRA_OPT="${2:-}"
    if [ -z $INTANCES ];then
      INTANCES=1
    fi
    if [[ "$EXTRA_OPT" == "GR" ]]; then
      if [[ "$ENCRYPTION" == 1 ]];then
        echoit "WARNING: Group Replication do not support binary log encryption due to binlog_checksum (PS-4819). Disabling encryption!"
        ENCRYPTION=0
      fi
      local GD_PORT1="$(( (RPORT + ( 35 * 1 )) + 10 ))"
      local GD_PORT2="$(( (RPORT + ( 35 * 2 )) + 10 ))"
      local GD_PORT3="$(( (RPORT + ( 35 * 3 )) + 10 ))"
	  local GD_PORTS=(0 $GD_PORT1 $GD_PORT2 $GD_PORT3)
    fi
    for i in `seq 1 $INTANCES`;do
      local STARTUP_OPTION="${2:-}"
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
      if [ "$ENGINE" == "innodb" ]; then
        echo "default-storage-engine=innodb" >> ${PS_BASEDIR}/n${i}.cnf
      elif [ "$ENGINE" == "rocksdb" ]; then
        echo "plugin-load-add=rocksdb=ha_rocksdb.so" >> ${PS_BASEDIR}/n${i}.cnf
        echo "init-file=${SCRIPT_PWD}/MyRocks.sql" >> ${PS_BASEDIR}/n${i}.cnf
        echo "default-storage-engine=rocksdb" >> ${PS_BASEDIR}/n${i}.cnf
        echo "rocksdb-flush-log-at-trx-commit=2" >> ${PS_BASEDIR}/n${i}.cnf
        echo "rocksdb-wal-recovery-mode=2" >> ${PS_BASEDIR}/n${i}.cnf
      elif [ "$ENGINE" == "tokudb" ]; then
        echo "plugin-load-add=tokudb=ha_tokudb.so" >> ${PS_BASEDIR}/n${i}.cnf
        echo "tokudb-check-jemalloc=0" >> ${PS_BASEDIR}/n${i}.cnf
        echo "init-file=${SCRIPT_PWD}/TokuDB.sql" >> ${PS_BASEDIR}/n${i}.cnf
        echo "default-storage-engine=tokudb" >> ${PS_BASEDIR}/n${i}.cnf
      fi
      if [[ "$EXTRA_OPT" == "GR" ]]; then
        echo "binlog_checksum=none" >> ${PS_BASEDIR}/n${i}.cnf
        echo "plugin_load=group_replication.so" >> ${PS_BASEDIR}/n${i}.cnf
        echo "transaction_write_set_extraction=XXHASH64" >> ${PS_BASEDIR}/n${i}.cnf
        echo "group_replication_group_name='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'" >> ${PS_BASEDIR}/n${i}.cnf
        echo "group_replication_start_on_boot=OFF" >> ${PS_BASEDIR}/n${i}.cnf
        echo "group_replication_local_address='$ADDR:${GD_PORTS[${i}]}'" >> ${PS_BASEDIR}/n${i}.cnf
        echo "group_replication_group_seeds='$ADDR:${GD_PORTS[1]},$ADDR:${GD_PORTS[2]},$ADDR:${GD_PORTS[3]}'" >> ${PS_BASEDIR}/n${i}.cnf
        echo "group_replication_bootstrap_group=OFF" >> ${PS_BASEDIR}/n${i}.cnf
        if check_for_version $MYSQL_VERSION "8.0.4" ; then
          echo "group_replication_recovery_get_public_key=ON" >> ${PS_BASEDIR}/n${i}.cnf
        fi
      fi
      if [[ "$EXTRA_OPT" == "MTR" ]]; then
        echo "slave-parallel-workers=5" >> ${PS_BASEDIR}/n${i}.cnf
      fi
      if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
        echo "gtid-mode=ON" >> ${PS_BASEDIR}/n${i}.cnf
        echo "enforce-gtid-consistency" >> ${PS_BASEDIR}/n${i}.cnf
      fi
      if [[ "$ENCRYPTION" == 1 ]];then
        if [[ "$EXTRA_OPT" != "GR" ]]; then
          if ! check_for_version $MYSQL_VERSION "8.0.16" ; then
            echo "encrypt_binlog=ON" >> ${PS_BASEDIR}/n${i}.cnf
            echo "innodb_encrypt_tables=OFF" >> ${PS_BASEDIR}/n${i}.cnf
          else
            echo "binlog_encryption=ON" >> ${PS_BASEDIR}/n${i}.cnf
            echo "default_table_encryption=OFF" >> ${PS_BASEDIR}/n${i}.cnf
          fi
          echo "master_verify_checksum=on" >> ${PS_BASEDIR}/n${i}.cnf
          echo "binlog_checksum=crc32" >> ${PS_BASEDIR}/n${i}.cnf.
          echo "innodb_temp_tablespace_encrypt=ON" >> ${PS_BASEDIR}/n${i}.cnf
          echo "encrypt-tmp-files=ON" >> ${PS_BASEDIR}/n${i}.cnf
          if [[ "$EXTRA_OPT" != "XB" ]]; then
            echo "innodb_sys_tablespace_encrypt=ON" >> ${PS_BASEDIR}/n${i}.cnf
          fi
  	      if [[ "$KEYRING_PLUGIN" == "file" ]]; then
            echo "early-plugin-load=keyring_file.so" >> ${PS_BASEDIR}/n${i}.cnf
            echo "keyring_file_data=$node/keyring" >> ${PS_BASEDIR}/n${i}.cnf
  	      elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
            echo "early-plugin-load=keyring_vault.so" >> ${PS_BASEDIR}/n${i}.cnf
            echo "keyring_vault_config=$WORKDIR/vault/keyring_vault_ps.cnf" >> ${PS_BASEDIR}/n${i}.cnf
          fi
        fi
      fi

      if [[ "$EXTRA_OPT" == "XB" ]]; then
        if [[ "$ENCRYPTION" == 1 ]];then
          if [[ "$KEYRING_PLUGIN" == "file" ]]; then
            ${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --early-plugin-load=keyring_file.so --keyring_file_data=keyring --basedir=${PS_BASEDIR} --datadir=$node > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;
          elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
            ${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --early-plugin-load=keyring_vault.so --keyring_vault_config=$WORKDIR/vault/keyring_vault_ps.cnf --basedir=${PS_BASEDIR} --datadir=$node > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;
          fi
        else
          ${MID} --datadir=$node  > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;
        fi
      elif [[ "$EXTRA_OPT" == "GR" ]]; then
        ${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PS_BASEDIR} --datadir=$node  > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;
      else
        ${MID} --datadir=$node  > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;
      fi

      ${PS_BASEDIR}/bin/mysqld --defaults-file=${PS_BASEDIR}/n${i}.cnf > $WORKDIR/logs/psnode${i}.err 2>&1 &

      for X in $(seq 0 ${PS_START_TIMEOUT}); do
        sleep 1
        if ${PS_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps${i}.sock ping > /dev/null 2>&1; then
          if [[ "$ENCRYPTION" == 1 ]];then
            if ! check_for_version $MYSQL_VERSION "8.0.16" ; then
              ${PS_BASEDIR}/bin/mysql  -uroot -S/tmp/ps${i}.sock -e"SET GLOBAL innodb_encrypt_tables=ON;"  > /dev/null 2>&1
            else
              ${PS_BASEDIR}/bin/mysql  -uroot -S/tmp/ps${i}.sock -e"SET GLOBAL default_table_encryption=ON;"  > /dev/null 2>&1
            fi
          fi
          break
        fi
        if [ $X -eq ${PS_START_TIMEOUT} ]; then
          echoit "PS startup failed.."
          grep "ERROR" ${WORKDIR}/logs/psnode${i}.err
          exit 1
          fi
      done
      if [[ "$EXTRA_OPT" == "GR" ]]; then
        if [[ $i -eq 1 ]]; then
          ${PS_BASEDIR}/bin/mysql -uroot -S/tmp/ps${i}.sock -e"CREATE USER rpl_user@'%'  IDENTIFIED BY 'rpl_pass';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%';CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';RESET MASTER;SET GLOBAL group_replication_bootstrap_group=ON;START GROUP_REPLICATION;SET GLOBAL group_replication_bootstrap_group=OFF;"
        else
          ${PS_BASEDIR}/bin/mysql -uroot -S/tmp/ps${i}.sock -e"CREATE USER rpl_user@'%'  IDENTIFIED BY 'rpl_pass';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%';CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';RESET MASTER;START GROUP_REPLICATION;"
        fi
      fi
    done
  }

  function run_pt_table_checksum(){
    local DATABASES=${1:-}
    local SOCKET=${2:-}
    local CHANNEL=${3:-}

    local CHANNEL_OPT=""
    if [[ "${CHANNEL}" != "none" ]]; then
      CHANNEL_OPT="--channel=${CHANNEL}"
    fi
    pt-table-checksum S=${SOCKET},u=test_user,p=test -d ${DATABASES} --recursion-method hosts --no-check-binlog-format ${CHANNEL_OPT}
    check_cmd $?
  }

  function run_mysqlchecksum(){
    local DATABASE=${1:-}
    local MASTER_SOCKET=${2:-}
    local SLAVE_SOCKET=${3:-}
    local TABLES_MASTER=$(${PS_BASEDIR}/bin/mysql -sN -uroot --socket=${MASTER_SOCKET} -e "SELECT GROUP_CONCAT(TABLE_NAME SEPARATOR \", \") FROM information_schema.tables WHERE table_schema = \"${DATABASE}\";")
    local TABLES_SLAVE=$(${PS_BASEDIR}/bin/mysql -sN -uroot --socket=${SLAVE_SOCKET} -e "SELECT GROUP_CONCAT(TABLE_NAME SEPARATOR \", \") FROM information_schema.tables WHERE table_schema = \"${DATABASE}\";")
    local CHECKSUM_MASTER=$(${PS_BASEDIR}/bin/mysql -sN -uroot --socket=${MASTER_SOCKET} -e "checksum table ${TABLES_MASTER};" -D ${DATABASE})
    local CHECKSUM_SLAVE=$(${PS_BASEDIR}/bin/mysql -sN -uroot --socket=${SLAVE_SOCKET} -e "checksum table ${TABLES_SLAVE};" -D ${DATABASE})

    echoit "Master ${MASTER_SOCKET} database ${DATABASE} tables: ${TABLES_MASTER}"
    echoit "Master ${MASTER_SOCKET} database ${DATABASE} checksums:"
    echoit "${CHECKSUM_MASTER}"
    echoit "Slave ${SLAVE_SOCKET} database ${DATABASE} tables: ${TABLES_SLAVE}"
    echoit "Slave ${SLAVE_SOCKET} database ${DATABASE} checksums:"
    echoit "${CHECKSUM_SLAVE}"
    if [[ -z "${TABLES_MASTER}" || -z "${TABLES_SLAVE}" || -z "${CHECKSUM_MASTER}" || -z "${CHECKSUM_SLAVE}" ]]; then
      echoit "One of the checksum values is empty!"
      exit 1
    elif [[ "${CHECKSUM_MASTER}" == "${CHECKSUM_SLAVE}" ]]; then
      echoit "Database checksums are the same."
    else
      echoit "Difference noticed in the checksums!"
      exit 1
    fi
  }

  function invoke_slave(){
    local MASTER_SOCKET=${1:-}
    local SLAVE_SOCKET=${2:-}
    local REPL_STRING=${3:-}
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -e"FLUSH LOGS"
    local MASTER_LOG_FILE=`${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "show master logs" | awk '{print $1}' | tail -1`
    local MASTER_HOST_PORT=`${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "select @@port"`
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_AUTO_POSITION=1 $REPL_STRING"
    else
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4 $REPL_STRING"
    fi
  }

  function slave_startup_check(){
    local SOCKET_FILE=${1:-}
    local SLAVE_STATUS=${2:-}
    local ERROR_LOG=${3:-}
    local MSR_SLAVE_STATUS=${4:-}
    local SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    local COUNTER=0
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
    local SOCKET_FILE=${1:-}
    local SLAVE_STATUS=${2:-}
    local ERROR_LOG=${3:-}
    local SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    local COUNTER=0
    while [[ $SB_MASTER -gt 0 ]]; do
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

  function create_test_user(){
    local SOCKET=${1:-}
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET -e "CREATE USER IF NOT EXISTS test_user@'%' identified with mysql_native_password by 'test';GRANT ALL ON *.* TO test_user@'%'" 2>&1
  }

  function async_sysbench_rw_run(){
    local MASTER_DB=${1:-}
    local SLAVE_DB=${2:-}
    local MASTER_SOCKET=${3:-}
    local SLAVE_SOCKET=${4:-}
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
    local DATABASE_NAME=${1:-}
    local SOCKET=${2:-}
    echoit "Sysbench insert run (Database: $DATABASE_NAME)"
    sysbench_run insert_data $DATABASE_NAME
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET run  > $WORKDIR/logs/sysbench_insert.log 2>&1
    check_cmd $? "Failed to execute sysbench insert run ($SOCKET)"
  }

  function async_sysbench_load(){
    local DATABASE_NAME=${1:-}
    local SOCKET=${2:-}
    echoit "Sysbench Run: Prepare stage (Database: $DATABASE_NAME)"
    sysbench_run load_data $DATABASE_NAME
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  > $WORKDIR/logs/sysbench_prepare.txt 2>&1
    check_cmd $? "Failed to execute sysbench prepare stage ($SOCKET)"
  }

  function gt_test_run(){
    local DATABASE_NAME=${1:-}
    local SOCKET=${2:-}
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "CREATE TABLESPACE ${DATABASE_NAME}_gen_ts1 ADD DATAFILE '${DATABASE_NAME}_gen_ts1.ibd' ENCRYPTION='Y'"  2>&1
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "CREATE TABLE ${DATABASE_NAME}_gen_ts_tb1(id int auto_increment, str varchar(32), primary key(id)) TABLESPACE ${DATABASE_NAME}_gen_ts1" 2>&1
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "CREATE TABLE ${DATABASE_NAME}_sys_ts_tb1(id int auto_increment, str varchar(32), primary key(id)) TABLESPACE=innodb_system" 2>&1
    local NUM_ROWS=$(shuf -i 50-100 -n 1)
    for i in `seq 1 $NUM_ROWS`; do
      local STRING=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "INSERT INTO ${DATABASE_NAME}_gen_ts_tb1 (str) VALUES ('${STRING}')"
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET $DATABASE_NAME -e "INSERT INTO ${DATABASE_NAME}_sys_ts_tb1 (str) VALUES ('${STRING}')"
    done
  }

  function backup_database(){
    rm -rf ${WORKDIR}/backupdir ${WORKDIR}/bkpslave; mkdir ${WORKDIR}/backupdir
    local SOCKET=${1:-}

    if [[ -z $ENCRYPTION ]]; then
      ${PXBBASE}/bin/xtrabackup --user=root --password='' --backup --target-dir=${WORKDIR}/backupdir/full -S${SOCKET} --datadir=${WORKDIR}/psnode1 > $WORKDIR/logs/xb_backup.log 2>&1

      echoit "Prepare xtrabackup"	
	  ${PXBBASE}/bin/xtrabackup --prepare --target-dir=${WORKDIR}/backupdir/full > $WORKDIR/logs/xb_prepare_backup.log 2>&1

    else
      if [[ "$KEYRING_PLUGIN" == "file" ]]; then
        ${PXBBASE}/bin/xtrabackup --user=root --password='' --backup --target-dir=${WORKDIR}/backupdir/full -S${SOCKET} --datadir=${WORKDIR}/psnode1 --keyring-file-data=${WORKDIR}/psnode1/keyring --xtrabackup-plugin-dir=${PXBBASE}/lib/plugin --generate-transition-key > $WORKDIR/logs/xb_backup.log 2>&1
        
        echoit "Prepare xtrabackup"	
        ${PXBBASE}/bin/xtrabackup --prepare --target-dir=${WORKDIR}/backupdir/full --keyring-file-data=${WORKDIR}/psnode1/keyring --xtrabackup-plugin-dir=${PXBBASE}/lib/plugin > $WORKDIR/logs/xb_prepare_backup.log 2>&1
        
      elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
        ${PXBBASE}/bin/xtrabackup --user=root --password='' --backup --target-dir=${WORKDIR}/backupdir/full -S${SOCKET} --datadir=${WORKDIR}/psnode1 --xtrabackup-plugin-dir=${PXBBASE}/lib/plugin --keyring-vault-config=$WORKDIR/vault/keyring_vault_ps.cnf --generate-transition-key > $WORKDIR/logs/xb_backup.log 2>&1
        
        echoit "Prepare xtrabackup"	
        ${PXBBASE}/bin/xtrabackup --prepare --target-dir=${WORKDIR}/backupdir/full --xtrabackup-plugin-dir=${PXBBASE}/lib/plugin --keyring-vault-config=$WORKDIR/vault/keyring_vault_ps.cnf > $WORKDIR/logs/xb_prepare_backup.log 2>&1
      fi
    fi
    echoit "Restore backup to slave datadir"
    rsync -avpP ${WORKDIR}/backupdir/full/ ${WORKDIR}/bkpslave > $WORKDIR/logs/xb_restore_backup.log 2>&1
    if [ -f ${WORKDIR}/psnode1/keyring ]; then
      cp ${WORKDIR}/psnode1/keyring ${WORKDIR}/bkpslave/
    fi
    cat ${PS_BASEDIR}/n1.cnf |
      sed -e "0,/^[ \t]*port[ \t]*=.*$/s|^[ \t]*port[ \t]*=.*$|port=3308|" |
      sed -e "0,/^[ \t]*report-port[ \t]*=.*$/s|^[ \t]*report-port[ \t]*=.*$|report-port=3308|" |
      sed -e "0,/^[ \t]*server-id[ \t]*=.*$/s|^[ \t]*server-id[ \t]*=.*$|server-id=200|" |
      sed -e "s|psnode1|bkpslave|g" |
      sed -e "0,/^[ \t]*socket[ \t]*=.*$/s|^[ \t]*socket[ \t]*=.*$|socket=/tmp/bkpslave.sock|"  > ${PS_BASEDIR}/bkpslave.cnf 2>&1

    ${PS_BASEDIR}/bin/mysqld --defaults-file=${PS_BASEDIR}/bkpslave.cnf > $WORKDIR/logs/bkpslave.err 2>&1 &

    for X in $(seq 0 ${PS_START_TIMEOUT}); do
      sleep 1
      if ${PS_BASEDIR}/bin/mysqladmin -uroot -S/tmp/bkpslave.sock ping > /dev/null 2>&1; then
        break
      fi
      if [ $X -eq ${PS_START_TIMEOUT} ]; then
        echoit "PS Slave startup failed.."
        grep "ERROR" ${WORKDIR}/logs/bkpslave.err
        exit 1
        fi
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
	create_test_user "/tmp/ps1.sock"
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
    if [ "$ENGINE" == "rocksdb" ]; then
      run_mysqlchecksum "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps2.sock"
    else
      run_pt_table_checksum "sbtest_ps_master" "/tmp/ps1.sock" "none"
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
    create_test_user "/tmp/ps1.sock"
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
    if [ "$ENGINE" == "rocksdb" ]; then
      run_mysqlchecksum "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps3.sock"
      run_mysqlchecksum "sbtest_ps_master" "/tmp/ps1.sock" "/tmp/ps4.sock"
    else
      run_pt_table_checksum "sbtest_ps_master" "/tmp/ps1.sock" "none"
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
    create_test_user "/tmp/ps1.sock"
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
    if [ "$ENGINE" == "rocksdb" ]; then
      run_mysqlchecksum "sbtest_ps_master_1" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "sbtest_ps_master_2" "/tmp/ps1.sock" "/tmp/ps2.sock"
    else
      run_pt_table_checksum "sbtest_ps_master_1,sbtest_ps_master_2" "/tmp/ps1.sock" "none"
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
	create_test_user "/tmp/ps2.sock"
	create_test_user "/tmp/ps3.sock"
	create_test_user "/tmp/ps4.sock"
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
    local SB_CHANNEL1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master1'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    local SB_CHANNEL2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master2'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    local SB_CHANNEL3=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

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

    if [ "$ENGINE" == "rocksdb" ]; then
      echoit "Checksum for msr_db_master1 database"
      run_mysqlchecksum "msr_db_master1" "/tmp/ps2.sock" "/tmp/ps1.sock"
      echoit "Checksum for msr_db_master2 database"
      run_mysqlchecksum "msr_db_master2" "/tmp/ps3.sock" "/tmp/ps1.sock"
      echoit "Checksum for msr_db_master3 database"
      run_mysqlchecksum "msr_db_master3" "/tmp/ps4.sock" "/tmp/ps1.sock"
    else
      echoit "Checksum for msr_db_master1 database"
      run_pt_table_checksum "msr_db_master1" "/tmp/ps2.sock" "master1"
      echoit "Checksum for msr_db_master2 database"
      run_pt_table_checksum "msr_db_master2" "/tmp/ps3.sock" "master2"
      echoit "Checksum for msr_db_master3 database"
      run_pt_table_checksum "msr_db_master3" "/tmp/ps4.sock" "master3"
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
    ps_start 2 "MTR"

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
	create_test_user "/tmp/ps1.sock"
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
    local SB_PS_1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    local SB_PS_2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

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
    if [ "$ENGINE" == "rocksdb" ]; then
      run_mysqlchecksum "mtr_db_ps1_1" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps1_2" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps1_3" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps1_4" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps1_5" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps2_1" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps2_2" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps2_3" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps2_4" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "mtr_db_ps2_5" "/tmp/ps1.sock" "/tmp/ps2.sock"
    else
      run_pt_table_checksum "mtr_db_ps1_1,mtr_db_ps1_2,mtr_db_ps1_3,mtr_db_ps1_4,mtr_db_ps1_5,mtr_db_ps2_1,mtr_db_ps2_2,mtr_db_ps2_3,mtr_db_ps2_4,mtr_db_ps2_5" "/tmp/ps1.sock" "none"
    fi

    #Shutdown PS servers
    echoit "Shuttingdown PS servers"
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }

  function mgr_test(){
    if [[ "$ENGINE" != "tokudb" && "$ENGINE" != "rocksdb" ]]; then
      echoit "******************** $MYEXTRA_CHECK mysql group replication test ************************"
      #PS server initialization
      echoit "PS server initialization for group replication test"
      ps_start 3 GR

      ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"drop database if exists sbtest_gr_db;create database sbtest_gr_db;"
      create_test_user "/tmp/ps1.sock"
      echoit "Running sysbench data load"
      async_sysbench_load sbtest_gr_db "/tmp/ps1.sock"
      async_sysbench_insert_run sbtest_gr_db "/tmp/ps1.sock"
      sleep 5

      if [ "$ENCRYPTION" == 1 ];then
        echoit "Running general tablespace encryption test run"
        gt_test_run sbtest_gr_db "/tmp/ps1.sock"
      fi
      sleep 30
      echoit "6. group replication: Checksum result."
      run_mysqlchecksum "sbtest_gr_db" "/tmp/ps1.sock" "/tmp/ps2.sock"
      run_mysqlchecksum "sbtest_gr_db" "/tmp/ps1.sock" "/tmp/ps3.sock"

      $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
      $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
      $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
      ENCRYPTION=1
    else
      echoit "Group replication is not supported for TokuDB/RocksDB!"
      return 0
    fi
  }

  function xb_master_slave_test(){
    if [[ "$ENGINE" == "tokudb" ]]; then
      echoit "XtraBackup doesn't support tokudb backup so skipping!"
      return 0
    elif ! check_for_version $MYSQL_VERSION "8.0.15" && [[ "$ENGINE" == "rocksdb" ]]; then
      echoit "XtraBackup 2.4 with PS 5.7 doesn't support rocksdb backup so skipping!"
      return 0
    elif ! check_for_version $MYSQL_VERSION "8.0.15" && [[ "$ENCRYPTION" == 1 ]]; then
      echoit "XtraBackup 2.4 with PS 5.7 supports only limited functionality for encryption so skipping!"
      return 0
    else
      echoit "********************$MYEXTRA_CHECK master slave test using xtrabackup ************************"
      #PS server initialization
      echoit "PS server initialization"
      ps_start 1 "XB"
      ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_xb_db;create database sbtest_xb_db;"
      create_test_user "/tmp/ps1.sock"
      async_sysbench_load sbtest_xb_db "/tmp/ps1.sock"
      async_sysbench_insert_run sbtest_xb_db "/tmp/ps1.sock"

      echoit "Check xtrabackup binary"
      check_xb_dir
      echoit "Initiate xtrabackup"
      backup_database "/tmp/ps1.sock"

      ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_xb_check;create database sbtest_xb_check;"
      ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "create table sbtest_xb_check.t1(id int);"
      local BINLOG_FILE=$(cat ${WORKDIR}/backupdir/full/xtrabackup_binlog_info | awk '{print $1}')
      local BINLOG_POS=$(cat ${WORKDIR}/backupdir/full/xtrabackup_binlog_info | awk '{print $2}')
      echoit "Starting replication on restored slave"
      local PORT=$(${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "select @@port")
      ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/bkpslave.sock -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$PORT, MASTER_USER='root', MASTER_LOG_FILE='$BINLOG_FILE',MASTER_LOG_POS=$BINLOG_POS;START SLAVE"

      slave_startup_check "/tmp/bkpslave.sock" "$WORKDIR/logs/slave_status_bkpslave.log" "$WORKDIR/logs/bkpslave.err"

      echoit "7. XB master slave replication: Checksum result."
      if [ "$ENGINE" == "rocksdb" ]; then
        run_mysqlchecksum "sbtest_xb_db" "/tmp/ps1.sock" "/tmp/bkpslave.sock"
        run_mysqlchecksum "sbtest_xb_check" "/tmp/ps1.sock" "/tmp/bkpslave.sock"
      else
        run_pt_table_checksum "sbtest_xb_db,sbtest_xb_check" "/tmp/ps1.sock" "none"
      fi
      $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
      $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/bkpslave.sock -u root shutdown
    fi
  }

  if [[ ! " ${TC_ARRAY[@]} " =~ " all " ]]; then
    for i in "${TC_ARRAY[@]}"; do
      if [[ "$i" == "master_slave_test" ]]; then
  	    master_slave_test
  	  elif [[ "$i" == "master_multi_slave_test" ]]; then
  	    master_multi_slave_test
  	  elif [[ "$i" == "xb_master_slave_test" ]]; then
        xb_master_slave_test
  	  elif [[ "$i" == "master_master_test" ]]; then
  	    master_master_test
  	  elif [[ "$i" == "msr_test" ]]; then
        if check_for_version $MYSQL_VERSION "5.7.0" ; then 
          msr_test
        fi
      elif [[ "$i" == "mtr_test" ]]; then
  	   mtr_test
      elif [[ "$i" == "mgr_test" ]]; then
       if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
         mgr_test
       fi
      fi
    done
  else
    master_slave_test
    master_multi_slave_test
    master_master_test
    if check_for_version $MYSQL_VERSION "5.7.0" ; then 
      msr_test
    fi
    mtr_test
    if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
      mgr_test
    fi
	  xb_master_slave_test
  fi  
}

async_rpl_test
async_rpl_test GTID
