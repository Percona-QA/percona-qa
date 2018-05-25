#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will test the data consistency between Percona XtraDB Cluster nodes.

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc-correctness-testing.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                     Specify work directory"
  echo "  -b, --build-number=NUMBER              Specify work build directory"
  echo "  -k, --keyring-plugin=[file|vault]      Specify which keyring plugin to use(default keyring-file)"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
  echo "  -e, --with-binlog-encryption           Run the script with binary log encryption feature"
  echo "  -c, --enable-checksum                  Run pt-table-checksum to check slave sync status"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:k:s:ech --longoptions=workdir:,build-number:,keyring-plugin:,with-binlog-encryption,enable-checksum,help \
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
    -e | --with-binlog-encryption )
    shift
    export BINLOG_ENCRYPTION=1
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
    -s | --sst-method )
    export SST_METHOD="$2"
    shift 2
    if [[ "$SST_METHOD" != "rsync" ]] && [[ "$SST_METHOD" != "xtrabackup-v2" ]] ; then
      echo "ERROR: Invalid --sst-method passed:"
      echo "  Please choose any of these sst-method options: 'rsync' or 'xtrabackup-v2'"
      exit 1
    fi
    ;;
    -c | --enable-checksum )
    shift
    export ENABLE_CHECKSUM=1
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

# generic variables
if [[ -z "$WORKDIR" ]]; then
  export WORKDIR=${PWD}
fi

ROOT_FS=$WORKDIR
if [[ -z "$SST_METHOD" ]]; then
  export SST_METHOD="xtrabackup-v2"
fi
SCRIPT_PWD=$(cd `dirname $0` && pwd)

cd $WORKDIR

#Check PXC binary tar ball
PXC_TAR=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep ".tar" | head -n1`
if [[ ! -z $PXC_TAR ]];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
else
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  if [[ -z $PXCBASE ]] ; then
    echoit "ERROR! Could not find PXC base directory."
    exit 1
  else
    export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
  fi
fi
BASEDIR="${ROOT_FS}/$PXCBASE"

PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
if [ ! -z $PT_TAR ];then
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
else
  wget https://www.percona.com/downloads/percona-toolkit/2.2.19/tarball/percona-toolkit-2.2.19.tar.gz
  PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
fi

# Parameter of parameterized build
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi
if [ -z ${SDURATION} ]; then
  SDURATION=30
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

EXTSTATUS=0

if [ ! -d ${ROOT_FS}/test_db ]; then
  git clone https://github.com/datacharmer/test_db.git
fi

function create_emp_db()
{
  DB_NAME=$1
  SE_NAME=$2
  SQL_FILE=$3
  pushd ${ROOT_FS}/test_db
  cat ${ROOT_FS}/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql
   $BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

echoit(){
  echo "[$(date +'%T')] $1"
  if [[ "${WORKDIR}" != "" ]]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/pxc-correctness-testing.log; fi
}

if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
  echoit "Setting up vault server"
  mkdir $WORKDIR/vault
  rm -rf $WORKDIR/vault/*
  killall vault
  echoit "********************************************************************************************"
  ${SCRIPT_PWD}/../vault_test_setup.sh --workdir=$WORKDIR/vault --setup-pxc-mount-points --use-ssl
  echoit "********************************************************************************************"
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

create_certs(){
  # Creating SSL certificate directories
  rm -rf ${WORKDIR}/certs* && mkdir -p ${WORKDIR}/certs && pushd ${WORKDIR}/certs
  # Creating CA certificate
  echoit "Creating CA certificate"
  openssl genrsa 2048 > ca-key.pem
  openssl req -new -x509 -nodes -days 3600 -key ca-key.pem -out ca.pem -subj '/CN=www.percona.com/O=Database Performance./C=US'

  # Creating server certificate
  echoit "Creating server certificate"
  openssl req -newkey rsa:2048 -days 3600 -nodes -keyout server-key.pem -out server-req.pem -subj '/CN=www.percona.com/O=Database Performance./C=AU'
  openssl rsa -in server-key.pem -out server-key.pem
  openssl x509 -req -in server-req.pem -days 3600 -CA ca.pem -CAkey ca-key.pem -set_serial 01 -out server-cert.pem
  popd
}

#mysql install db check

if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
fi

archives() {
  tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
  rm -rf $WORKDIR
}

trap archives EXIT KILL

ps -ef | grep 'pxc[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

SBENCH="sysbench"

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

echoit "Setting PXC Port"
ADDR="127.0.0.1"
RPORT=$(( (RANDOM%21 + 10)*1000 ))
LADDR="$ADDR:$(( RPORT + 8 ))"
PXC_START_TIMEOUT=200

SUSER=root
SPASS=

if [[ ! -z $KEYRING_PLUGIN ]] || [[ ! -z $BINLOG_ENCRYPTION ]]; then
  echoit "Generating SSL certificates"
  create_certs
fi
	
function pxc_start(){
  for i in `seq 1 3`;do
    RBASE1="$(( RPORT + ( 100 * $i ) ))"
    LADDR1="127.0.0.1:$(( RBASE1 + 8 ))"
    if [ $i -eq 1 ];then
      WSREP_CLUSTER="gcomm://"
    else
      WSREP_CLUSTER="$WSREP_CLUSTER,gcomm://$LADDR1"
    fi
    WSREP_CLUSTER_STRING="$WSREP_CLUSTER"
    echoit "Starting PXC node${i}"
    node="${WORKDIR}/node${i}"
    rm -rf $node
    if [[ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]]; then
      mkdir -p $node
    fi

    # Creating PXC configuration file
    rm -rf ${WORKDIR}/n${i}.cnf
    echo "[mysqld]" > ${WORKDIR}/n${i}.cnf
    echo "basedir=${BASEDIR}" >> ${WORKDIR}/n${i}.cnf
    echo "datadir=$node" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep-debug=ON" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_cluster_address=$WSREP_CLUSTER" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1" >> ${WORKDIR}/n${i}.cnf
    echo "log-error=${WORKDIR}/logs/node${i}.err" >> ${WORKDIR}/n${i}.cnf
    echo "socket=/tmp/pxc${i}.sock" >> ${WORKDIR}/n${i}.cnf
    echo "port=$RBASE1" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_node_incoming_address=127.0.0.1" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_node_address=127.0.0.1" >> ${WORKDIR}/n${i}.cnf
    echo "innodb_file_per_table" >> ${WORKDIR}/n${i}.cnf
    echo "innodb_autoinc_lock_mode=2" >> ${WORKDIR}/n${i}.cnf
    echo "innodb_locks_unsafe_for_binlog=1" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep-provider=${BASEDIR}/lib/libgalera_smm.so" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_sst_method=$SST_METHOD" >> ${WORKDIR}/n${i}.cnf
    echo "log-bin=mysql-bin" >> ${WORKDIR}/n${i}.cnf
    echo "master-info-repository=TABLE" >> ${WORKDIR}/n${i}.cnf
    echo "relay-log-info-repository=TABLE" >> ${WORKDIR}/n${i}.cnf
    echo "core-file" >> ${WORKDIR}/n${i}.cnf
    echo "log-output=none" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_slave_threads=2" >> ${WORKDIR}/n${i}.cnf
    echo "server-id=10${i}" >> ${WORKDIR}/n${i}.cnf
    if [[ "$BINLOG_ENCRYPTION" == 1 ]];then
      echo "encrypt_binlog" >> ${WORKDIR}/n${i}.cnf
      echo "master_verify_checksum=on" >> ${WORKDIR}/n${i}.cnf
      echo "binlog_checksum=crc32" >> ${WORKDIR}/n${i}.cnf
      echo "innodb_encrypt_tables=ON" >> ${WORKDIR}/n${i}.cnf
	  if [[ -z $KEYRING_PLUGIN ]]; then
        echo "early-plugin-load=keyring_file.so" >> ${WORKDIR}/n${i}.cnf
        echo "keyring_file_data=$node/keyring" >> ${WORKDIR}/n${i}.cnf
      fi
    fi
	if [[ "$KEYRING_PLUGIN" == "file" ]]; then
      echo "early-plugin-load=keyring_file.so" >> ${WORKDIR}/n${i}.cnf
      echo "keyring_file_data=$node/keyring" >> ${WORKDIR}/n${i}.cnf
    fi
	if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
      echo "early-plugin-load=keyring_vault.so" >> ${WORKDIR}/n${i}.cnf
      echo "loose-keyring_vault_config=$WORKDIR/vault/keyring_vault_pxc${i}.cnf" >> ${WORKDIR}/n${i}.cnf
    fi	
    echo "" >> ${WORKDIR}/n${i}.cnf
    echo "[sst]" >> ${WORKDIR}/n${i}.cnf
    echo "encrypt = 4" >> ${WORKDIR}/n${i}.cnf
    echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> ${WORKDIR}/n${i}.cnf
    echo "ssl-cert=${WORKDIR}/certs/server-cert.pem" >> ${WORKDIR}/n${i}.cnf
    echo "ssl-key=${WORKDIR}/certs/server-key.pem" >> ${WORKDIR}/n${i}.cnf

    ${MID} --datadir=$node  > ${WORKDIR}/logs/node${i}.err 2>&1 || exit 1;

    ${BASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/n${i}.cnf  > ${WORKDIR}/logs/node${i}.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc${i}.sock ping > /dev/null 2>&1; then
        WSREP_STATE=0
        COUNTER=0
        while [[ $WSREP_STATE -ne 4 ]]; do
          WSREP_STATE=$(${BASEDIR}/bin/mysql -uroot -S/tmp/pxc${i}.sock -Bse"show status like 'wsrep_local_state'" | awk '{print $2}')
          echoit "WSREP: Synchronized with group, ready for connections"
          let COUNTER=COUNTER+1
          if [[ $COUNTER -eq 50 ]];then
            echoit "WARNING! WSREP: Node is not synchronized with group. Checking slave status"
            break
          fi
          sleep 3
        done
        break
      fi
      if [[ $X -eq ${PXC_START_TIMEOUT} ]]; then
        echoit "PXC startup failed.."
        grep "ERROR" ${WORKDIR}/logs/node${i}.err
        exit 1
	  fi
    done
    if [[ $i -eq 1 ]];then
      cp $node/*.pem $WORKDIR/certs/
      WSREP_CLUSTER="gcomm://$LADDR1"
      export NODE1_PORT=$RBASE1
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists pxc_test;create database pxc_test;drop database if exists percona;create database percona;"
      # Create DSNs table to run pt-table-checksum
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100), primary key(id));"
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "insert into percona.dsns (id,dsn) values (1,'h=127.0.0.1,P=$RBASE1,u=root');"
    else
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "insert into percona.dsns (id,dsn) values (${i},'h=127.0.0.1,P=$RBASE1,u=root');"
    fi
  done
}

pxc_start

check_script(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID}. Terminating!"; exit 1; fi
}

#Sysbench prepare run
echoit "Initiating sysbench dataload"
sysbench_run load_data pxc_test
$SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
check_script $? "Failed to run sysbench dataload"

if [[ ${PIPESTATUS[0]} -ne 0 ]];then
  echoit "Sysbench run failed"
  EXTSTATUS=1
fi

echoit "Loading sakila test database"
#$BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql
$BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root < ${SCRIPT_PWD}/sample_db/sakila_workaround_bug81497.sql
check_script $? "Failed to load sakila test database"

echoit "Loading world test database"
$BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql
check_script $? "Failed to load world test datbase"

echoit "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql
check_script $? "Failed to load employees database with innodb engine"

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql
check_script $? "Failed to load employees partitioned database with innodb engine"

for i in {1..5}; do
  # Sysbench transaction run
  echoit "Initiating sysbench insert run"
  sysbench_run oltp pxc_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock run 2>&1 | tee $WORKDIR/logs/sysbench_rw_run.log
  check_script $? "Failed to run sysbench read write run"
  # Run pt-table-checksum to analyze data consistency
  if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
    $BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root -e "set global pxc_strict_mode=DISABLED"
    pt-table-checksum h=127.0.0.1,P=$NODE1_PORT,u=root -d pxc_test,world,employee_1,employee_2 --recursion-method dsn=h=127.0.0.1,P=$NODE1_PORT,u=root,D=percona,t=dsns
    check_script $? "Failed to run pt-table-checksum"
    $BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root -e "set global pxc_strict_mode=ENFORCING"
  else
    pt-table-checksum h=127.0.0.1,P=$NODE1_PORT,u=root -d pxc_test,world,employee_1,employee_2 --recursion-method dsn=h=127.0.0.1,P=$NODE1_PORT,u=root,D=percona,t=dsns
    check_script $? "Failed to run pt-table-checksum"
  fi
  if [[ $i -eq 5 ]];then
    if [[ $? -eq 0 ]];then
      echoit "PXC correctness test run completed!"
    fi
  fi
done

exit $EXTSTATUS

