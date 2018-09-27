#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will test following replication features in Percona XtraDB Cluster.
# Master-Slave replication test
# Master-Master replication test
# Master-Slave shuffle replication test
# Multi Source replication test
# Multi thread replication test
# Dispay script usage details

usage () {
  echo "Usage:"
  echo "  pxc-async-repl-test_v2.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                Specify work directory"
  echo "  -b, --build-number=NUMBER         Specify work build directory"
  echo "  -l, --binlog-format=FORMAT        Specify mysql binary log format(default ROW)"
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
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
  echo "  -e, --with-encryption             Run the script with encryption features"
  echo "  -c, --enable-checksum             Run pt-table-checksum to check slave sync status"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:k:l:t:s:ech --longoptions=workdir:,build-number:,binlog-format:,keyring-plugin:,testcase:,sst-method:,with-encryption,help \
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
    -l | --binlog-format )
    export BINLOG_FORMAT="$2"
	shift 2
    if [[ "$BINLOG_FORMAT" != "ROW" ]] && [[ "$BINLOG_FORMAT" != "MIXED" ]] && [[ "$BINLOG_FORMAT" != "STATEMENT" ]] ; then
      echo "ERROR: Invalid --binlog-format passed:"
      echo "  Please choose any of these binlog-format options: 'ROW', 'MIXED', or 'STATEMENT'"
      exit 1
    fi
    ;;
    -t | --testcase )
    export TESTCASE="$2"
	shift 2
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

if [[ -z "$BINLOG_FORMAT" ]];then
  BINLOG_FORMAT="ROW"
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
PXC_START_TIMEOUT=200
cd $WORKDIR
# For local run - User Configurable Variables
if [[ -z ${BUILD_NUMBER} ]]; then
  BUILD_NUMBER=1001
fi

if [[ -z ${SDURATION} ]]; then
  SDURATION=30
fi

if [[ -z ${SST_METHOD} ]]; then
  SST_METHOD=rsync
fi

if [[ -z ${TSIZE} ]]; then
  TSIZE=5000
fi

if [[ -z ${NUMT} ]]; then
  NUMT=16
fi

if [[ -z ${TCOUNT} ]]; then
  TCOUNT=16
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
rm -rf $WORKDIR/*
mkdir -p $WORKDIR/logs

echoit(){
  echo "[$(date +'%T')] $1"
  if [[ "${WORKDIR}" != "" ]]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/pxc_async_test.log; fi
}

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

if [[ ! -z $KEYRING_PLUGIN ]] || [[ ! -z $ENCRYPTION ]]; then
  echoit "Generating SSL certificates"
  create_certs
fi

if [[ "$KEYRING_PLUGIN" == "file" ]]; then
  MYEXTRA_KEYRING="--early-plugin-load=keyring_file.so --keyring_file_data=keyring"
elif [[ "$KEYRING_PLUGIN" == "vault" ]]; then
  echoit "Setting up vault server"
  mkdir $WORKDIR/vault
  rm -rf $WORKDIR/vault/*
  killall vault
  echoit "********************************************************************************************"
  ${SCRIPT_PWD}/../vault_test_setup.sh --workdir=$WORKDIR/vault --setup-pxc-mount-points --use-ssl
  echoit "********************************************************************************************"
fi

#Kill existing mysqld process
ps -ef | grep 'pxc[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
ps -ef | grep 'ps[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

#Check SST method
if [[ $SST_METHOD == xtrabackup ]];then
  SST_METHOD=xtrabackup-v2
  TAR=`ls -1ct percona-xtrabackup*.tar.gz 2>/dev/null | head -n1`
  tar -xf $TAR
  BBASE=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$BBASE/bin:$PATH"
fi

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
PXC_BASEDIR="${ROOT_FS}/$PXCBASE"

#Check Percona Toolkit binary tar ball
PT_TAR=`ls -1td ?ercona-?oolkit* 2>/dev/null | grep ".tar" | head -n1`
if [[ ! -z $PT_TAR ]];then
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* 2>/dev/null | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
else
  wget https://www.percona.com/downloads/percona-toolkit/2.2.16/tarball/percona-toolkit-2.2.16.tar.gz
  PT_TAR=`ls -1td ?ercona-?oolkit* 2>/dev/null | grep ".tar" | head -n1`
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* 2>/dev/null | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
fi

#Check sysbench
if [[ ! -e `which sysbench` ]];then
    echoit "Sysbench not found"
    exit 1
fi
echoit "Note: Using sysbench at $(which sysbench)"

echoit "Setting PXC/PS Port"
ADDR="127.0.0.1"
RPORT=$(( (RANDOM%21 + 10)*1000 ))
LADDR="$ADDR:$(( RPORT + 8 ))"
SUSER=root
SPASS=

#sysbench command should compatible with versions 0.5 and 1.0
sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [[ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]]; then
    if [[ "$TEST_TYPE" == "load_data" ]];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    elif [[ "$TEST_TYPE" == "oltp" ]];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [[ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]]; then
    if [[ "$TEST_TYPE" == "load_data" ]];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --db-driver=mysql"
    elif [[ "$TEST_TYPE" == "oltp" ]];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

#mysql install db check
if [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]]; then
  MID="${PXC_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXC_BASEDIR}"
elif [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]]; then
  MID="${PXC_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXC_BASEDIR}"
fi

#Check command failure
check_cmd(){
  MPID=$1
  ERROR_MSG=$2
  if [[ ${MPID} -ne 0 ]]; then echoit "ERROR: $ERROR_MSG. Terminating!"; exit 1; fi
}

#Setting PXC strict mode for running PT table checksum.
set_pxc_strict_mode(){
  MODE=$1
  if [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.6" ]]; then
    $PXC_BASEDIR/bin/mysql --socket=/tmp/pxc1.sock -u root -e "set global pxc_strict_mode=$MODE"
  fi
}

#Async replication test
function async_rpl_test(){
  MYEXTRA_CHECK=$1
  function pxc_start(){
    for i in `seq 1 3`;do
      STARTUP_OPTION="$1"
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
      if [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]]; then
        mkdir -p $node
      fi
	  
      # Creating PXC configuration file
      rm -rf ${PXC_BASEDIR}/n${i}.cnf
      echo "[mysqld]" > ${PXC_BASEDIR}/n${i}.cnf
      echo "basedir=${PXC_BASEDIR}" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "datadir=$node" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep-debug=ON" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_cluster_address=$WSREP_CLUSTER" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "log-error=${WORKDIR}/logs/node${i}.err" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "socket=/tmp/pxc${i}.sock" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "port=$RBASE1" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_node_incoming_address=127.0.0.1" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_node_address=127.0.0.1" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "innodb_file_per_table" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "innodb_autoinc_lock_mode=2" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "innodb_locks_unsafe_for_binlog=1" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep-provider=${PXC_BASEDIR}/lib/libgalera_smm.so" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_sst_method=$SST_METHOD" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "log-bin=mysql-bin" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "master-info-repository=TABLE" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "relay-log-info-repository=TABLE" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "core-file" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "log-output=none" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "wsrep_slave_threads=2" >> ${PXC_BASEDIR}/n${i}.cnf
      echo "server-id=10${i}" >> ${PXC_BASEDIR}/n${i}.cnf
      if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
        echo "gtid-mode=ON" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "log-slave-updates" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "enforce-gtid-consistency" >> ${PXC_BASEDIR}/n${i}.cnf
      else
        echo "log-slave-updates" >> ${PXC_BASEDIR}/n${i}.cnf
      fi
      if [[ "$ENCRYPTION" == 1 ]];then
        #echo "encrypt_binlog" >> ${PXC_BASEDIR}/n${i}.cnf
        #echo "master_verify_checksum=on" >> ${PXC_BASEDIR}/n${i}.cnf
        #echo "binlog_checksum=crc32" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "innodb_temp_tablespace_encrypt=ON" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "encrypt-tmp-files=ON" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "innodb_encrypt_tables=ON" >> ${PXC_BASEDIR}/n${i}.cnf
  	  if [[ -z $KEYRING_PLUGIN ]]; then
          echo "early-plugin-load=keyring_file.so" >> ${PXC_BASEDIR}/n${i}.cnf
          echo "keyring_file_data=$node/keyring" >> ${PXC_BASEDIR}/n${i}.cnf
        fi
      fi
  	if [[ "$KEYRING_PLUGIN" == "file" ]]; then
        echo "early-plugin-load=keyring_file.so" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "keyring_file_data=$node/keyring" >> ${PXC_BASEDIR}/n${i}.cnf
      fi
  	if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
        echo "early-plugin-load=\"keyring_vault=keyring_vault.so\"" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "keyring_vault_config=$WORKDIR/vault/keyring_vault_pxc${i}.cnf" >> ${PXC_BASEDIR}/n${i}.cnf
      fi
      if [[ "$ENCRYPTION" == 1 ]] || [[ "$KEYRING_PLUGIN" == "file" ]] || [[ "$KEYRING_PLUGIN" == "vault" ]] ;then
        echo "" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "[sst]" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "encrypt = 4" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "ssl-cert=${WORKDIR}/certs/server-cert.pem" >> ${PXC_BASEDIR}/n${i}.cnf
        echo "ssl-key=${WORKDIR}/certs/server-key.pem" >> ${PXC_BASEDIR}/n${i}.cnf
      fi
	
      ${MID} --datadir=$node  > ${WORKDIR}/logs/node${i}.err 2>&1 || exit 1;

      ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/n${i}.cnf $STARTUP_OPTION > ${WORKDIR}/logs/node${i}.err 2>&1 &

      for X in $(seq 0 ${PXC_START_TIMEOUT}); do
        sleep 1
        if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc${i}.sock ping > /dev/null 2>&1; then
          WSREP_STATE=0
          COUNTER=0
          while [[ $WSREP_STATE -ne 4 ]]; do
            WSREP_STATE=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/pxc${i}.sock -Bse"show status like 'wsrep_local_state'" | awk '{print $2}')
            if [[ $WSREP_STATE -eq 4 ]]; then
              echoit "WSREP: Synchronized with group, ready for connections"
            fi
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
      fi
	done
  }
  function ps_start(){
    INTANCES="$1"
	if [[ -z $INTANCES ]];then
	  INTANCES=1
	fi
    for i in `seq 1 $INTANCES`;do
      STARTUP_OPTION="$2"
	  RBASE1="$(( (RPORT + ( 100 * $i )) + $i ))"
      echoit "Starting independent PS node${i}.."
	  node="${WORKDIR}/psnode${i}"
	  rm -rf $node
      if [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]]; then
        mkdir -p $node
      fi
	  
      rm -rf ${PXC_BASEDIR}/ps${i}.cnf
      echo "[mysqld]" > ${PXC_BASEDIR}/ps${i}.cnf
      echo "basedir=${PXC_BASEDIR}" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "datadir=$node" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "log-error=${WORKDIR}/logs/psnode${i}.err" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "socket=/tmp/ps${i}.sock" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "port=$RBASE1" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "innodb_file_per_table" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "log-bin=mysql-bin" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "master-info-repository=TABLE" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "relay-log-info-repository=TABLE" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "core-file" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "log-output=none" >> ${PXC_BASEDIR}/ps${i}.cnf
      echo "server-id=20${i}" >> ${PXC_BASEDIR}/ps${i}.cnf
      if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
        echo "gtid-mode=ON" >> ${PXC_BASEDIR}/ps${i}.cnf
        echo "log-slave-updates" >> ${PXC_BASEDIR}/ps${i}.cnf
        echo "enforce-gtid-consistency" >> ${PXC_BASEDIR}/ps${i}.cnf
      else
        echo "log-slave-updates" >> ${PXC_BASEDIR}/ps${i}.cnf
      fi
      if [[ "$ENCRYPTION" == 1 ]];then
        #echo "encrypt_binlog" >> ${PXC_BASEDIR}/ps${i}.cnf
        #echo "master_verify_checksum=on" >> ${PXC_BASEDIR}/ps${i}.cnf
        #echo "binlog_checksum=crc32" >> ${PXC_BASEDIR}/ps${i}.cnf
        echo "innodb_encrypt_tables=ON" >> ${PXC_BASEDIR}/ps${i}.cnf
  	    if [[ -z $KEYRING_PLUGIN ]]; then
          echo "early-plugin-load=keyring_file.so" >> ${PXC_BASEDIR}/ps${i}.cnf
          echo "keyring_file_data=$node/keyring" >> ${PXC_BASEDIR}/ps${i}.cnf
        fi
      fi
  	  if [[ "$KEYRING_PLUGIN" == "file" ]]; then
        echo "early-plugin-load=keyring_file.so" >> ${PXC_BASEDIR}/ps${i}.cnf
        echo "keyring_file_data=$node/keyring" >> ${PXC_BASEDIR}/ps${i}.cnf
      fi
  	  if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
        echo "early-plugin-load=\"keyring_vault=keyring_vault.so\"" >> ${PXC_BASEDIR}/ps${i}.cnf
        echo "keyring_vault_config=$WORKDIR/vault/keyring_vault.cnf" >> ${PXC_BASEDIR}/ps${i}.cnf
      fi

      ${MID} --datadir=$node  > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;

      ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/ps${i}.cnf $STARTUP_OPTION  > $WORKDIR/logs/psnode${i}.err 2>&1 &

      for X in $(seq 0 ${PXC_START_TIMEOUT}); do
        sleep 1
        if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps${i}.sock ping > /dev/null 2>&1; then
          break
        fi
	    if [[ $X -eq ${PXC_START_TIMEOUT} ]]; then
	      echoit "PS startup failed.."
          grep "ERROR" ${WORKDIR}/logs/psnode${i}.err
          exit 1
  	    fi
      done
	done
  }

  function run_pt_table_checksum(){
	DATABASES=$1
	LOG_FILE=$2
    set_pxc_strict_mode DISABLED
	pt-table-checksum S=/tmp/pxc1.sock,u=root -d $DATABASES --recursion-method cluster --no-check-binlog-format
    check_cmd $?
    set_pxc_strict_mode ENFORCING
  }

  function invoke_slave(){
    MASTER_SOCKET=$1
	SLAVE_SOCKET=$2
	REPL_STRING=$3
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PXC_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "show master logs" | awk '{print $1}' | tail -1`
	MASTER_HOST_PORT=`${PXC_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "select @@port"`
    if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_AUTO_POSITION=1 $REPL_STRING"
    else
      ${PXC_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4 $REPL_STRING"
    fi
  }

  function slave_startup_check(){
	SOCKET_FILE=$1
	SLAVE_STATUS=$2
	ERROR_LOG=$3
	MSR_SLAVE_STATUS=$4
    SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [[ $COUNTER -eq 10 ]];then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" > $SLAVE_STATUS
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
	SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
	COUNTER=0
    while [[ $SB_MASTER -gt 0 ]]; do
      SB_MASTER=`${PXC_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echoit "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      else
        if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
	      let COUNTER=COUNTER+1
          sleep 5
	      if [[ $COUNTER -eq 300 ]]; then
	        echoit "WARNING! Seems slave second behind master is not moving forward, skipping slave sync status check"
		    break
	      fi
        else
          break
        fi
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
    #check_cmd $? "Failed to execute sysbench oltp read/write run on master ($MASTER_SOCKET)"

	#OLTP RW run on slave
	echoit "OLTP RW run on slave (Database: $SLAVE_DB)"
    sysbench_run oltp $SLAVE_DB
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SLAVE_SOCKET run  > $WORKDIR/logs/sysbench_slave_rw.log 2>&1
    #check_cmd $? "Failed to execute sysbench oltp read/write run on slave($SLAVE_SOCKET)"
  }

  function async_sysbench_load(){
    DATABASE_NAME=$1
    SOCKET=$2
    echoit "Sysbench Run: Prepare stage (Database: $DATABASE_NAME)"
    sysbench_run load_data $DATABASE_NAME
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  > $WORKDIR/logs/sysbench_prepare.txt 2>&1
	check_cmd $?
  }

  function node1_master_test(){
    echoit "******************** $MYEXTRA_CHECK PXC node-1 as master ************************"
	#PXC/PS server initialization
	echoit "PXC/PS server initialization"
	pxc_start
    ps_start

	invoke_slave "/tmp/pxc1.sock" "/tmp/ps1.sock" ";START SLAVE;"

    echoit "Checking slave startup"
	slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_slave;create database sbtest_ps_slave;"
	${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists sbtest_pxc_master;create database sbtest_pxc_master;"
	async_sysbench_load sbtest_pxc_master "/tmp/pxc1.sock"
	async_sysbench_load sbtest_ps_slave "/tmp/ps1.sock"

	async_sysbench_rw_run sbtest_pxc_master sbtest_ps_slave "/tmp/pxc1.sock" "/tmp/ps1.sock"
	sleep 5
    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"
    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      sleep 10
	  echoit "PXC node-1 as master: Checksum result."
	  run_pt_table_checksum "sbtest_pxc_master" "$WORKDIR/logs/node1_master_checksum.log"
    else
      echoit "PXC node-1 as master: replication looks good."
    fi
	#Shutdown PXC/PS servers
	echoit "Shutdown PXC/PS servers"
	$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
  }

  function node1_slave_test(){
    echoit "********************$MYEXTRA_CHECK PXC-as-slave (node-1) from independent master ************************"
	#PXC/PS server initialization
	echoit "PXC/PS server initialization"
	pxc_start "--slave_parallel_workers=2"
    ps_start

	invoke_slave "/tmp/ps1.sock" "/tmp/pxc1.sock" ";START SLAVE;"

	echoit "Checking slave startup"
	slave_startup_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists sbtest_pxc_slave;create database sbtest_pxc_slave;"
	${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
	async_sysbench_load sbtest_pxc_slave "/tmp/pxc1.sock"
	async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"

	async_sysbench_rw_run sbtest_ps_master sbtest_pxc_slave "/tmp/ps1.sock" "/tmp/pxc1.sock"
	sleep 5
    echoit "Checking slave sync status"
    slave_sync_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err"
    sleep 10

	PS_UUID=$(${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show global variables like 'gtid_executed'" | awk '{print $2}'  | cut -d":" -f1)
    PXC_NODE1_UUID=$(${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show global variables like 'gtid_executed'" | awk '{print $2}'  | cut -d":" -f1)
	PXC_NODE2_UUID=$(${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -Bse "show global variables like 'gtid_executed'" | awk '{print $2}'  | cut -d":" -f1)
	PXC_NODE3_UUID=$(${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc3.sock -Bse "show global variables like 'gtid_executed'" | awk '{print $2}'  | cut -d":" -f1)

    if [[ "$MYEXTRA_CHECK" == "GTID" ]]; then
	  if [[ "$PS_UUID" != "$PXC_NODE1_UUID" ]];then
	    echoit "ERROR! GTID consistency failed. PS master UUID is not matching with PXC node1 UUID. Terminating."
		exit 1
	  fi
	  	  if [[ "$PS_UUID" != "$PXC_NODE2_UUID" ]];then
	    echoit "ERROR! GTID consistency failed. PS master UUID is not matching with PXC node2 UUID. Terminating."
		exit 1
	  fi
	  if [[ "$PS_UUID" != "$PXC_NODE3_UUID" ]];then
	    echoit "ERROR! GTID consistency failed. PS master UUID is not matching with PXC node3 UUID. Terminating."
		exit 1
	  fi
	fi

    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      echoit "PXC-as-slave (node-1) from independent master: Checksum result."
	  run_pt_table_checksum "sbtest_ps_master" "$WORKDIR/logs/node1_slave_checksum.log"
    else
      echoit "PXC-as-slave (node-1) from independent master: replication looks good."
    fi

    #Shutdown PXC/PS servers
	echoit "Shutdown PXC/PS servers"
	$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
  }

  function node2_slave_test(){
    echoit "********************$MYEXTRA_CHECK PXC-as-slave (node-2) from independent master ************************"
	#PXC/PS server initialization
	echoit "PXC/PS server initialization"
	pxc_start
    ps_start

    invoke_slave "/tmp/ps1.sock" "/tmp/pxc2.sock" ";START SLAVE;"

	echoit "Checking slave startup"
	slave_startup_check "/tmp/pxc2.sock" "$WORKDIR/logs/slave_status_node2.log" "$WORKDIR/logs/node2.err"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e "drop database if exists sbtest_pxc_slave;create database sbtest_pxc_slave;"
	${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
	async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"
	async_sysbench_load sbtest_pxc_slave "/tmp/pxc2.sock"

	async_sysbench_rw_run sbtest_ps_master sbtest_pxc_slave "/tmp/ps1.sock" "/tmp/pxc2.sock"
	sleep 5
    echoit "Checking slave sync status"
    slave_sync_check "/tmp/pxc2.sock" "$WORKDIR/logs/slave_status_node2.log" "$WORKDIR/logs/node2.err"
    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      sleep 10
      echoit "PXC-as-slave (node-2) from independent master: Checksum result."
	  run_pt_table_checksum "sbtest_pxc_slave" "$WORKDIR/logs/node2_slave_checksum.log"
    else
      echoit "PXC-as-slave (node-2) from independent master: replication looks good."
    fi

    #Shutdown PXC/PS servers
	echoit "Shutdown PXC/PS servers"
	$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
  }

  function pxc_master_slave_shuffle_test(){
    echoit "********************$MYEXTRA_CHECK PXC - master - and - slave ************************"
	#PXC/PS server initialization
	echoit "PXC/PS server initialization"
	pxc_start
    ps_start

	invoke_slave "/tmp/pxc1.sock" "/tmp/ps1.sock" ";START SLAVE;"
	invoke_slave "/tmp/ps1.sock" "/tmp/pxc1.sock" ";START SLAVE;"

	echoit "Checking PXC slave startup"
	slave_startup_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err"
	echoit "Checking PS slave startup"
	slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc2.sock -e "drop database if exists sbtest_pxc_db;create database sbtest_pxc_db;"
	${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_db;create database sbtest_ps_db;"
	async_sysbench_load sbtest_ps_db "/tmp/ps1.sock"
	async_sysbench_load sbtest_pxc_db "/tmp/pxc2.sock"

	async_sysbench_rw_run sbtest_ps_db sbtest_pxc_db "/tmp/ps1.sock" "/tmp/pxc1.sock"
	sleep 5
    echoit "Checking PXC slave sync status"
    slave_sync_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err"
	sleep 5
    echoit "Checking slave PS sync status"
    slave_sync_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"
    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      sleep 10
      echoit "PXC - master - and - slave: Checksum result."
	  run_pt_table_checksum "sbtest_pxc_db,sbtest_ps_db" "$WORKDIR/logs/node1_slave_checksum.log"
    else
      echoit "PXC - master - and - slave: replication looks good."
    fi

    echoit "********************$MYEXTRA_CHECK PXC - master - and - slave shuffle test ************************"
	MASTER_HOST_PORT=`$PXC_BASEDIR/bin/mysql  --socket=/tmp/pxc2.sock -u root -Bse "select @@port"`
	LADDR="$ADDR:$(( MASTER_HOST_PORT + 8 ))"
    echo "Stopping PXC node1 for shuffle test"
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown > /dev/null 2>&1
    sleep 20
    echo "Start PXC node2 for shuffle test"
    ${PXC_BASEDIR}/bin/mysqld --defaults-file=${PXC_BASEDIR}/n2.cnf $STARTUP_OPTION > ${WORKDIR}/logs/node2.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXC_BASEDIR}/bin/mysqladmin -uroot -S/tmp/pxc2.sock ping > /dev/null 2>&1; then
        WSREP_STATE=0
        COUNTER=0
        while [[ $WSREP_STATE -ne 4 ]]; do
          WSREP_STATE=$(${PXC_BASEDIR}/bin/mysql -uroot -S/tmp/pxc2.sock -Bse"show status like 'wsrep_local_state'" | awk '{print $2}')
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
	    echoit "PXC node2 startup failed.."
        grep "ERROR" ${WORKDIR}/logs/node2.err
        exit 1
  	  fi
    done
    sleep 5

	invoke_slave "/tmp/ps1.sock" "/tmp/pxc2.sock" ";START SLAVE;"
	echoit "Checking slave startup"
	slave_startup_check "/tmp/pxc2.sock" "$WORKDIR/logs/slave_status_node2.log" "$WORKDIR/logs/node2.err"
	sleep 5
	${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
	async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"

    async_sysbench_rw_run sbtest_ps_master sbtest_pxc_db "/tmp/ps1.sock" "/tmp/pxc2.sock"
	sleep 5

	echoit "Checking slave sync status"
    slave_sync_check "/tmp/pxc2.sock" "$WORKDIR/logs/slave_status_node2.log" "$WORKDIR/logs/node2.err"
    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      sleep 10
      echoit "PXC shuffle master - and - slave : Checksum result."
	  run_pt_table_checksum "test" "$WORKDIR/logs/pxc_master_slave_shuffle_checksum.log"
    else
      echoit "PXC shuffle master - and - slave : replication looks good."
    fi
    #Shutdown PXC/PS servers
	echoit "Shutdown PXC/PS servers"
	$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
  }

  function pxc_msr_test(){
    echoit "********************$MYEXTRA_CHECK PXC - multi source replication test ************************"
    #PXC/PS server initialization
	echoit "PXC/PS server initialization"
	pxc_start
    ps_start 3
    echo "Sysbench Run for replication master master test : Prepare stage"
    invoke_slave "/tmp/ps1.sock" "/tmp/pxc1.sock" "FOR CHANNEL 'master1';"
	invoke_slave "/tmp/ps2.sock" "/tmp/pxc1.sock" "FOR CHANNEL 'master2';"
	invoke_slave "/tmp/ps3.sock" "/tmp/pxc1.sock" "FOR CHANNEL 'master3';"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e"START SLAVE;"
	slave_startup_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err" "for channel 'master1'"
	slave_startup_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err" "for channel 'master2'"
	slave_startup_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err" "for channel 'master3'"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists msr_db_master1;create database msr_db_master1;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists msr_db_master2;create database msr_db_master2;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e "drop database if exists msr_db_master3;create database msr_db_master3;"
	${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists msr_db_slave;create database msr_db_slave;"
    sleep 5
    # Sysbench dataload for MSR test
	async_sysbench_load msr_db_master1 "/tmp/ps1.sock"
	async_sysbench_load msr_db_master2 "/tmp/ps2.sock"
	async_sysbench_load msr_db_master3 "/tmp/ps3.sock"

    sysbench_run oltp msr_db_master1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_ps_channel1_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp msr_db_master2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_ps_channel2_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp msr_db_master3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock  run  > $WORKDIR/logs/sysbench_ps_channel3_rw.log 2>&1
    check_cmd $?

    sleep 10
    SB_CHANNEL1=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master1'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL2=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master2'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL3=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    if ! [[ "$SB_CHANNEL1" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL2" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
      exit 1
    fi

    while [[ $SB_CHANNEL3 -gt 0 ]]; do
      SB_CHANNEL3=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
        echo "Slave is not started yet. Please check error log : $WORKDIR/logs/node1.err"
        exit 1
      else
        if [[ $ENABLE_CHECKSUM -ne 1 ]]; then
          break
        fi
      fi
      sleep 5
    done
    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      sleep 10
	  echoit "PXC - multi source replication: Checksum result."
	  run_pt_table_checksum "msr_db_master1,msr_db_master2,msr_db_master3" "$WORKDIR/logs/pxc_msr_checksum.log"
    else
      echoit "PXC - multi source replication: replication looks good."
    fi
    #Shutdown PXC/PS servers for MSR test
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
  }

  function pxc_mtr_test(){
    echoit "********************$MYEXTRA_CHECK PXC - multi thread replication test ************************"
    #PXC/PS server initialization
	echoit "PXC/PS server initialization"
	pxc_start "--slave-parallel-workers=5"
    ps_start 3 "--slave-parallel-workers=5"

    echoit "Sysbench Run for replication master master test : Prepare stage"
	invoke_slave "/tmp/ps2.sock" "/tmp/pxc1.sock" ";START SLAVE;"
	invoke_slave "/tmp/pxc1.sock" "/tmp/ps2.sock" ";START SLAVE;"

	slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
	slave_startup_check "/tmp/pxc1.sock" "$WORKDIR/logs/slave_status_node1.log" "$WORKDIR/logs/node1.err"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc1;create database mtr_db_pxc1;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc2;create database mtr_db_pxc2;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc3;create database mtr_db_pxc3;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc4;create database mtr_db_pxc4;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -e "drop database if exists mtr_db_pxc5;create database mtr_db_pxc5;"

    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps1;create database mtr_db_ps1;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2;create database mtr_db_ps2;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps3;create database mtr_db_ps3;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps4;create database mtr_db_ps4;"
    ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps5;create database mtr_db_ps5;"

    sleep 5
    # Sysbench dataload for MTR test
	echoit "Sysbench dataload for MTR test"
	async_sysbench_load mtr_db_pxc1 "/tmp/pxc1.sock"
	async_sysbench_load mtr_db_pxc2 "/tmp/pxc1.sock"
	async_sysbench_load mtr_db_pxc3 "/tmp/pxc1.sock"
	async_sysbench_load mtr_db_pxc4 "/tmp/pxc1.sock"
	async_sysbench_load mtr_db_pxc5 "/tmp/pxc1.sock"

	async_sysbench_load mtr_db_ps1 "/tmp/ps2.sock"
	async_sysbench_load mtr_db_ps2 "/tmp/ps2.sock"
	async_sysbench_load mtr_db_ps3 "/tmp/ps2.sock"
	async_sysbench_load mtr_db_ps4 "/tmp/ps2.sock"
	async_sysbench_load mtr_db_ps5 "/tmp/ps2.sock"

    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_pxc1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc1_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_pxc2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc2_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_pxc3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc3_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_pxc4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc4_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_pxc5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/pxc1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_pxc5_rw.log 2>&1 &
    check_cmd $?
    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_ps1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps3_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps4_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps5_rw.log 2>&1
    check_cmd $?
    sleep 10
    SB_PS=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_PXC=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    while [[ $SB_PS -gt 0 ]]; do
      SB_PS=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PS" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode2.log
        echoit "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/node2.err,  $WORKDIR/logs/slave_status_psnode2.log"
        exit 1
      else
        if [[ $ENABLE_CHECKSUM -ne 1 ]]; then
          break
        fi
      fi
      sleep 5
    done

    while [[ $SB_PXC -gt 0 ]]; do
      SB_PXC=`$PXC_BASEDIR/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PXC" =~ ^[0-9]+$ ]]; then
        ${PXC_BASEDIR}/bin/mysql -uroot --socket=/tmp/pxc1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_node1.log
        echoit "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_node1.log"
        exit 1
      else
        if [[ $ENABLE_CHECKSUM -ne 1 ]]; then
          break
        fi
      fi
      sleep 5
    done
    if [[ $ENABLE_CHECKSUM -eq 1 ]]; then
      sleep 10
	  echoit "PXC - multi thread replication: Checksum result."
	  run_pt_table_checksum "mtr_db_pxc1,mtr_db_pxc2,mtr_db_pxc3,mtr_db_pxc4,mtr_db_pxc5,mtr_db_ps1,mtr_db_ps2,mtr_db_ps3,mtr_db_ps4,mtr_db_ps5" "$WORKDIR/logs/pxc_mtr_checksum.log"
    else
      echoit "PXC - multi thread replication: replication looks good."
    fi
	#Shutdown PXC/PS servers
	echoit "Shuttingdown PXC/PS servers"
	$PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PXC_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
  }

  if [[ ! " ${TC_ARRAY[@]} " =~ " all " ]]; then
    for i in "${TC_ARRAY[@]}"; do
      if [[ "$i" == "node1_master_test" ]]; then
  	    node1_master_test
  	  elif [[ "$i" == "node1_slave_test" ]]; then
  	    node1_slave_test
  	  elif [[ "$i" == "node2_slave_test" ]]; then
  	    node2_slave_test
  	  elif [[ "$i" == "pxc_master_slave_shuffle_test" ]]; then
  	    pxc_master_slave_shuffle_test
  	  elif [[ "$i" == "pxc_msr_test" ]]; then
        if [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.6" ]]; then
          pxc_msr_test
        fi
      elif [[ "$i" == "pxc_mtr_test" ]]; then
  	   pxc_mtr_test
      fi
    done
  else
    node1_master_test
    node1_slave_test
    node2_slave_test
    pxc_master_slave_shuffle_test
    if [[ "$(${PXC_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.6" ]]; then
      pxc_msr_test
    fi
    pxc_mtr_test
  fi

}

async_rpl_test
async_rpl_test GTID
