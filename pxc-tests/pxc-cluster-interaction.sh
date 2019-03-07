#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will test the cluster interaction.

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc-cluster-interaction.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                     Specify work directory"
  echo "  -b, --build-number=NUMBER              Specify work build directory"
  echo "  -k, --keyring-plugin=[file|vault]      Specify which keyring plugin to use(default keyring-file)"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
  echo "  -e, --with-encryption                  Run the script with encryption features"
  echo "  -c, --enable-checksum                  Run pt-table-checksum to check slave sync status"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:k:s:ech --longoptions=workdir:,build-number:,keyring-plugin:,sst-method:,with-encryption,enable-checksum,help \
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
    -e | --with-encryption )
    shift
    export ENCRYPTION=1
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

# Parameter of parameterized build
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi
if [ -z ${SDURATION} ]; then
  SDURATION=1000
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

EXTSTATUS=0

check_script(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID}. Terminating!"; exit 1; fi
}

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

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

echoit(){
  echo "[$(date +'%T')] $1"
  if [[ "${WORKDIR}" != "" ]]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/pxc-correctness-testing.log; fi
}

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
  wget https://www.percona.com/downloads/percona-toolkit/3.0.13/binary/tarball/percona-toolkit-3.0.13_x86_64.tar.gz
  PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
fi

if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
  echoit "Setting up vault server"
  mkdir $WORKDIR/vault
  rm -rf $WORKDIR/vault/*
  killall vault
  echoit "********************************************************************************************"
  ${SCRIPT_PWD}/../vault_test_setup.sh --workdir=$WORKDIR/vault --setup-pxc-mount-points --use-ssl
  echoit "********************************************************************************************"
fi

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

declare MYSQL_VERSION=$(${BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
#mysql install db check
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
else
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
fi

archives() {
  tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
  killall vault
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
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=sysbench --mysql-password=test  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=sysbench --mysql-password=test  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=sysbench --mysql-password=test  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=sysbench --mysql-password=test  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
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

if [[ ! -z $KEYRING_PLUGIN ]] || [[ ! -z $ENCRYPTION ]]; then
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
    if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
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
    if ! check_for_version $MYSQL_VERSION "8.0.0" ; then
      echo "innodb_locks_unsafe_for_binlog=1" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${WORKDIR}/n${i}.cnf
    fi
    echo "wsrep-provider=${BASEDIR}/lib/libgalera_smm.so" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_sst_method=$SST_METHOD" >> ${WORKDIR}/n${i}.cnf
    echo "log-bin=mysql-bin" >> ${WORKDIR}/n${i}.cnf
    echo "master-info-repository=TABLE" >> ${WORKDIR}/n${i}.cnf
    echo "relay-log-info-repository=TABLE" >> ${WORKDIR}/n${i}.cnf
    echo "core-file" >> ${WORKDIR}/n${i}.cnf
    echo "log-output=none" >> ${WORKDIR}/n${i}.cnf
    echo "wsrep_slave_threads=2" >> ${WORKDIR}/n${i}.cnf
    echo "server-id=10${i}" >> ${WORKDIR}/n${i}.cnf
    if [[ "$ENCRYPTION" == 1 ]];then
      #echo "encrypt_binlog" >> ${WORKDIR}/n${i}.cnf
      #echo "master_verify_checksum=on" >> ${WORKDIR}/n${i}.cnf
      #echo "binlog_checksum=crc32" >> ${WORKDIR}/n${i}.cnf
      echo "innodb_temp_tablespace_encrypt=ON" >> ${WORKDIR}/n${i}.cnf
      echo "encrypt-tmp-files=ON" >> ${WORKDIR}/n${i}.cnf
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
      echo "early-plugin-load=\"keyring_vault=keyring_vault.so\"" >> ${WORKDIR}/n${i}.cnf
      echo "keyring_vault_config=$WORKDIR/vault/keyring_vault_pxc${i}.cnf" >> ${WORKDIR}/n${i}.cnf
    fi
    if [[ "$ENCRYPTION" == 1 ]] || [[ "$KEYRING_PLUGIN" == "file" ]] || [[ "$KEYRING_PLUGIN" == "vault" ]] ;then
      echo "" >> ${WORKDIR}/n${i}.cnf
      echo "[sst]" >> ${WORKDIR}/n${i}.cnf
      echo "encrypt = 4" >> ${WORKDIR}/n${i}.cnf
      echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> ${WORKDIR}/n${i}.cnf
      echo "ssl-cert=${WORKDIR}/certs/server-cert.pem" >> ${WORKDIR}/n${i}.cnf
      echo "ssl-key=${WORKDIR}/certs/server-key.pem" >> ${WORKDIR}/n${i}.cnf
    fi

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
      WSREP_CLUSTER="gcomm://$LADDR1"
      export NODE1_PORT=$RBASE1
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists pxc_test;create database pxc_test;drop database if exists percona;create database percona;"
      # Create DSNs table to run pt-table-checksum
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100), primary key(id));"
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "insert into percona.dsns (id,dsn) values (1,'h=127.0.0.1,P=$RBASE1,u=root');"
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "create user sysbench@'%' identified with  mysql_native_password by 'test';"
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "grant all on *.* to sysbench@'%';"
    else
      $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "insert into percona.dsns (id,dsn) values (${i},'h=127.0.0.1,P=$RBASE1,u=root');"
    fi
  done
}

pxc_start

flow_control_test(){
  #Sysbench prepare run
  echoit "Initiating sysbench dataload"
  sysbench_run load_data pxc_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt
  check_script $? "Failed to run sysbench dataload"
  
  echoit "Initiating sysbench insert run"
  sysbench_run oltp pxc_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock run > $WORKDIR/logs/sysbench_rw_run.log &
  check_script $? "Failed to run sysbench read write run"
  for j in `seq 1 3`; do
    $BASEDIR/bin/mysql -uroot --socket=/tmp/pxc2.sock pxc_test -e "flush table sbtest1 with read lock;select sleep(60);unlock tables" > /dev/null 2>&1 &
    FLOW_CONTROL_STATUS=OFF
    while ! [[  "$FLOW_CONTROL_STATUS" == "OFF" ]]; do
      FLOW_CONTROL_STATUS=`/data/work/pxc80/bin/mysql -uroot -S/tmp/pxc2.sock -Bse "show status like 'wsrep_flow_control_status'" | awk '{ print $2 }'`
      echoit "PXC node2 flow control status : $FLOW_CONTROL_STATUS"
      sleep 1;
    done
  done
  # Run pt-table-checksum to analyze data consistency
  #if check_for_version $MYSQL_VERSION "5.7.0" ; then 
  #  $BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root -e "set global pxc_strict_mode=DISABLED"
  #  pt-table-checksum h=127.0.0.1,P=$NODE1_PORT,u=root -d pxc_test --recursion-method dsn=h=127.0.0.1,P=$NODE1_PORT,u=root,D=percona,t=dsns
  #  check_script $? "Failed to run pt-table-checksum"
  #  $BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root -e "set global pxc_strict_mode=ENFORCING"
  #else
  #  pt-table-checksum h=127.0.0.1,P=$NODE1_PORT,u=root -d pxc_test --recursion-method dsn=h=127.0.0.1,P=$NODE1_PORT,u=root,D=percona,t=dsns
  #  check_script $? "Failed to run pt-table-checksum"
  #fi
  pkill sysbench  > /dev/null 2>&1
}

flow_control_test

exit $EXTSTATUS
