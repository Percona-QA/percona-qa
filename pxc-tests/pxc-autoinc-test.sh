#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Quick Percona XtraDB Cluster startup script with configuration file.

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc-quick-start.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH           Specify work directory"
  echo "  -b, --basedir=PATH           Specify base directory"
  echo "  -a, --auto-inc-test          Start auto increment test with Percona XtraDB Cluster"
  echo "  -s, --auto-inc-shuffle-test  Start auto increment shuffle test with Percona XtraDB Cluster"
  echo "  -f, --data-infile=PATH       Specify sql file"
  echo "  -k, --with-keyring-plugin    Run the script with keyring-file plugin"
  echo "  -e, --with-binlog-encryption Run the script with binary log encryption feature"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:f:sakeh --longoptions=workdir:,basedir:,data-infile:,auto-inc-test,auto-inc-shuffle-test,with-keyring-plugin,with-binlog-encryption,help \
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
    -b | --basedir )
    export BASEDIR="$2"
    if [[ ! -d "$BASEDIR" ]]; then
      echo "ERROR: Basedir ($BASEDIR) directory does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -f | --data-infile )
    export DATA_INFILE="$2"
    if [[ ! -f "$DATA_INFILE" ]]; then
      echo "ERROR: SQL file does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -a | --auto-inc-test )
    shift
    export AUTO_INC_TEST=1
    ;;
    -s | --auto-inc-shuffle-test )
    shift
    export AUTO_INC_SHUFFLE_TEST=1
    ;;
    -e | --with-binlog-encryption )
    shift
    export BINLOG_ENCRYPTION=1
    ;;
    -k | --with-keyring-plugin )
    shift
    export KEYRING_PLUGIN=1
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
ROOT_FS=$WORKDIR
if [[ -z "$BASEDIR" ]]; then
  export BASEDIR=${PWD}
fi
SCRIPT_PWD=$(cd `dirname $0` && pwd)
PQUERY_RUN_TIMEOUT=60
PXC_CLUSTER_CONFIG=${SCRIPT_PWD}/../pquery/pquery-cluster.cfg
cd $WORKDIR

echoit(){
  echo "[$(date +'%T')] $1"
  if [[ "${WORKDIR}" != "" ]]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/pxc-quick-start.log; fi
}

#Check xtrabackup binary
if [[ ! -e `which xtrabackup` ]];then
    echoit "ERROR! xtrabackup not in $PATH"
    exit 1
fi
# Check mysqld binary
if [ -r ${BASEDIR}/bin/mysqld ]; then
  BIN=${BASEDIR}/bin/mysqld
else
  # Check if this is a debug build by checking if debug string is present in dirname
  if [[ ${BASEDIR} = *debug* ]]; then
    if [ -r ${BASEDIR}/bin/mysqld-debug ]; then
      BIN=${BASEDIR}/bin/mysqld-debug
    else
      echoit "Assert: there is no (script readable) mysqld binary at ${BASEDIR}/bin/mysqld[-debug] ?"
      exit 1
    fi
  else
    echoit "Assert: there is no (script readable) mysqld binary at ${BASEDIR}/bin/mysqld ?"
    exit 1
  fi
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

REQUIRED_VERSION=$(grep "XB_REQUIRED_VERSION=" ${BASEDIR}/bin/wsrep_sst_xtrabackup-v2 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*')
CURRENT_VERSION=$(xtrabackup --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

if ! check_for_version $CURRENT_VERSION $REQUIRED_VERSION ; then 
  echoit "The xtrabackup version is $CURRENT_VERSION. Needs xtrabackup-$REQUIRED_VERSION or higher to perform SST";
  exit 1  
fi

EXTSTATUS=0

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
declare MYSQL_VERSION=$(${BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
if check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
else
  MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
fi

ps -ef | grep 'pxc[0-9].sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

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

function startup_check(){
  SOCKET=$1
  ERRORLOG=$2
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$SOCKET ping > /dev/null 2>&1; then
      WSREP_STATE=0
      COUNTER=0
      while [[ $WSREP_STATE -ne 4 ]]; do
        WSREP_STATE=$(${BASEDIR}/bin/mysql -uroot -S${SOCKET} -Bse"show status like 'wsrep_local_state'" | awk '{print $2}')
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
      grep "ERROR" ${ERRORLOG}
      exit 1
	  fi
  done
}
	
function pxc_start(){
  for i in `seq 1 3`;do
    if [[ "$1" == "start" ]]; then
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
      echo "socket=$node/node${i}_socket.sock" >> ${WORKDIR}/n${i}.cnf
      echo "port=$RBASE1" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep_node_incoming_address=127.0.0.1" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep_node_address=127.0.0.1" >> ${WORKDIR}/n${i}.cnf
      echo "innodb_file_per_table" >> ${WORKDIR}/n${i}.cnf
      echo "innodb_autoinc_lock_mode=2" >> ${WORKDIR}/n${i}.cnf
      echo "innodb_locks_unsafe_for_binlog=1" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep-provider=${BASEDIR}/lib/libgalera_smm.so" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep_sst_auth=$SUSER:$SPASS" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep_sst_method=xtrabackup-v2" >> ${WORKDIR}/n${i}.cnf
      echo "log-bin=mysql-bin" >> ${WORKDIR}/n${i}.cnf
      echo "master-info-repository=TABLE" >> ${WORKDIR}/n${i}.cnf
      echo "relay-log-info-repository=TABLE" >> ${WORKDIR}/n${i}.cnf
      echo "core-file" >> ${WORKDIR}/n${i}.cnf
      echo "log-output=none" >> ${WORKDIR}/n${i}.cnf
      echo "wsrep_slave_threads=2" >> ${WORKDIR}/n${i}.cnf
      echo "server-id=10${i}" >> ${WORKDIR}/n${i}.cnf
      if [[ ! -z $BINLOG_ENCRYPTION ]];then
        echo "encrypt_binlog" >> ${WORKDIR}/n${i}.cnf
        echo "master_verify_checksum=on" >> ${WORKDIR}/n${i}.cnf
        echo "binlog_checksum=crc32" >> ${WORKDIR}/n${i}.cnf
        echo "innodb_encrypt_tables=ON" >> ${WORKDIR}/n${i}.cnf
  	    if [[ -z $KEYRING_PLUGIN ]]; then
          echo "early-plugin-load=keyring_file.so" >> ${WORKDIR}/n${i}.cnf
          echo "keyring_file_data=$node/keyring" >> ${WORKDIR}/n${i}.cnf
        fi
      fi
  	  if [[ ! -z $KEYRING_PLUGIN ]]; then
        echo "early-plugin-load=keyring_file.so" >> ${WORKDIR}/n${i}.cnf
        echo "keyring_file_data=$node/keyring" >> ${WORKDIR}/n${i}.cnf
      fi

      if [[ ! -z $KEYRING_PLUGIN ]] || [[ ! -z $BINLOG_ENCRYPTION ]]; then
        echo "" >> ${WORKDIR}/n${i}.cnf
        echo "[sst]" >> ${WORKDIR}/n${i}.cnf
        echo "encrypt = 4" >> ${WORKDIR}/n${i}.cnf
        echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> ${WORKDIR}/n${i}.cnf
        echo "ssl-cert=${WORKDIR}/certs/server-cert.pem" >> ${WORKDIR}/n${i}.cnf
        echo "ssl-key=${WORKDIR}/certs/server-key.pem" >> ${WORKDIR}/n${i}.cnf
      fi
  
      ${MID} --datadir=$node  > ${WORKDIR}/logs/node${i}.err 2>&1 || exit 1;
    else
      if [[ ! -d ${WORKDIR}/node${i} ]]; then
        echoit "ERROR! ${WORKDIR}/node${i} does not exist. Terminating."
        exit 1
	  fi
    fi

    ${BASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/n${i}.cnf  > ${WORKDIR}/logs/node${i}.err 2>&1 &
    startup_check "$node/node${i}_socket.sock" "${WORKDIR}/logs/node${i}.err"

    if [[ $i -eq 1 ]];then
      WSREP_CLUSTER="gcomm://$LADDR1"
    fi
  done
}

if [[ $AUTO_INC_TEST -eq 1 ]]; then
  rm -rf ${WORKDIR}/pquery
  mkdir ${WORKDIR}/pquery
  pxc_start start
  $BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -e"create database test"
  cat ${PXC_CLUSTER_CONFIG} \
   | sed -e "s|\/tmp|${WORKDIR}|" \
   | sed -e "s|[ \t]*infile[ \t]*=.*$|infile = $DATA_INFILE|" \
    > ${WORKDIR}/pquery-cluster.cfg
  ${SCRIPT_PWD}/../pquery/pquery2-pxc --config-file=${WORKDIR}/pquery-cluster.cfg > ${WORKDIR}/logs/pquery.log 2>&1 &
  PQPID="$!"
  for X in $(seq 1 ${PQUERY_RUN_TIMEOUT}); do
    sleep 1
    if [ "`ps -ef | grep ${PQPID} | grep -v grep`" == "" ]; then  # pquery ended
      break
    fi
    if [ $X -ge ${PQUERY_RUN_TIMEOUT} ]; then
      echoit "${PQUERY_RUN_TIMEOUT}s timeout reached. Terminating this trial..."
      TIMEOUT_REACHED=1
      break
    fi
  done
  (sleep 0.2; kill -9 ${PQPID} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${PQPID} >/dev/null 2>&1) &  # Terminate pquery

  n1_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
  n1_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
  while [[ "$n1_wsrep_recv_queue" !=  "0" ]] && [[ "$n1_wsrep_send_queue" !=  "0" ]]; do
    n1_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
    n1_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
	sleep 1
  done
  
  n2_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
  n2_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
  while [[ "$n2_wsrep_recv_queue" !=  "0" ]] && [[ "$n2_wsrep_send_queue" !=  "0" ]]; do
    n2_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
    n2_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
	sleep 1
  done
  
  n3_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
  n3_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
  while [[ "$n3_wsrep_recv_queue" !=  "0" ]] && [[ "$n3_wsrep_send_queue" !=  "0" ]]; do
    n3_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
    n3_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
	sleep 1
  done

  DISTINCT_T1_COUNT_N1=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"select count(distinct c1) from test.t1")
  DISTINCT_T1_COUNT_N2=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"select count(distinct c1) from test.t1")
  DISTINCT_T1_COUNT_N3=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"select count(distinct c1) from test.t1")
  DISTINCT_T2_COUNT_N1=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"select count(distinct c1) from test.t2")
  DISTINCT_T2_COUNT_N2=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"select count(distinct c1) from test.t2")
  DISTINCT_T2_COUNT_N3=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"select count(distinct c1) from test.t2")
  DISTINCT_T3_COUNT_N1=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"select count(distinct c1) from test.t3")
  DISTINCT_T3_COUNT_N2=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"select count(distinct c1) from test.t3")
  DISTINCT_T3_COUNT_N3=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"select count(distinct c1) from test.t3")

  function output_format(){
    divider===============================
    divider=$divider$divider
    header="\n %-10s %10s %10s %10s\n"
    format=" %-10s %10d %10d %10d\n"
     
    width=43
     
    printf "$header" "tname" "n1_rows" "n2_rows" "n3_rows"
     
    printf "%$width.${width}s\n" "$divider"
     
    printf "$format" \
    t1 $DISTINCT_T1_COUNT_N1  $DISTINCT_T1_COUNT_N2 $DISTINCT_T1_COUNT_N3 \
    t2 $DISTINCT_T2_COUNT_N1  $DISTINCT_T2_COUNT_N2 $DISTINCT_T2_COUNT_N3 \
    t3 $DISTINCT_T3_COUNT_N1  $DISTINCT_T3_COUNT_N2 $DISTINCT_T3_COUNT_N3 
  }
  output_format
  echoit "Shuttingdown PXC"
  $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node3/node3_socket.sock -u root shutdown
  echoit "Server on socket ${WORKDIR}/node3/node3_socket.sock with datadir $WORKDIR/node3 halted."
  $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node2/node2_socket.sock -u root shutdown
  echoit "Server on socket ${WORKDIR}/node2/node2_socket.sock with datadir $WORKDIR/node2 halted."
  $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node1/node1_socket.sock -u root shutdown
  echoit "Server on socket ${WORKDIR}/node1/node1_socket.sock with datadir $WORKDIR/node1 halted."
  
fi

if [[ $AUTO_INC_SHUFFLE_TEST -eq 1 ]]; then
  rm -rf ${WORKDIR}/pquery
  mkdir ${WORKDIR}/pquery
  pxc_start start
  $BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -e"create database test"
  cat ${PXC_CLUSTER_CONFIG} \
   | sed -e "s|\/tmp|${WORKDIR}|" \
   | sed -e "s|[ \t]*infile[ \t]*=.*$|infile = $DATA_INFILE|" \
    > ${WORKDIR}/pquery-cluster.cfg
  ${SCRIPT_PWD}/../pquery/pquery2-pxc --config-file=${WORKDIR}/pquery-cluster.cfg > ${WORKDIR}/pquery/pquery.log 2>&1 &
  PQPID="$!"
  for X in $(seq 1 ${PQUERY_RUN_TIMEOUT}); do
    sleep 1
    if [ "`ps -ef | grep ${PQPID} | grep -v grep`" == "" ]; then  # pquery ended
      break
    fi
    if [ $X -eq 30 ];then
      $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node3/node3_socket.sock -u root shutdown
      echoit "Server on socket ${WORKDIR}/node3/node3_socket.sock with datadir $WORKDIR/node3 halted."
	  sleep 3
      ${BASEDIR}/bin/mysqld --defaults-file=${WORKDIR}/n3.cnf  > ${WORKDIR}/logs/node3.err 2>&1 &
      startup_check "${WORKDIR}/node3/node3_socket.sock" "${WORKDIR}/logs/node3.err"
      
	  ${SCRIPT_PWD}/../pquery/pquery2-pxc --infile=${DATA_INFILE} --database=test --threads=1 --queries-per-thread=10000 --logdir=${WORKDIR}/pquery --log-all-queries --log-failed-queries --no-shuffle --log-query-statistics --user=root --socket=${WORKDIR}/node3/node3_socket.sock >${WORKDIR}/pquery/pquery_single.log 2>&1 &
      PQPID_1="$!"
    fi
    if [ $X -ge ${PQUERY_RUN_TIMEOUT} ]; then
      echoit "${PQUERY_RUN_TIMEOUT}s timeout reached. Terminating this trial..."
      TIMEOUT_REACHED=1
      break
    fi
  done
  (sleep 0.2; kill -9 ${PQPID} ${PQPID_1} >/dev/null 2>&1; timeout -k5 -s9 5s wait ${PQPID} ${PQPID_1} >/dev/null 2>&1) &  # Terminate pquery

  n1_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
  n1_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
  while [[ "$n1_wsrep_recv_queue" !=  "0" ]] && [[ "$n1_wsrep_send_queue" !=  "0" ]]; do
    n1_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
    n1_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
	sleep 1
  done
  
  n2_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
  n2_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
  while [[ "$n2_wsrep_recv_queue" !=  "0" ]] && [[ "$n2_wsrep_send_queue" !=  "0" ]]; do
    n2_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
    n2_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
	sleep 1
  done
  
  n3_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
  n3_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
  while [[ "$n3_wsrep_recv_queue" !=  "0" ]] && [[ "$n3_wsrep_send_queue" !=  "0" ]]; do
    n3_wsrep_recv_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_recv_queue'" | awk '{print $2}')
    n3_wsrep_send_queue=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"show global status like 'wsrep_local_send_queue'" | awk '{print $2}')
	sleep 1
  done

  DISTINCT_T1_COUNT_N1=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"select count(distinct c1) from test.t1")
  DISTINCT_T1_COUNT_N2=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"select count(distinct c1) from test.t1")
  DISTINCT_T1_COUNT_N3=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"select count(distinct c1) from test.t1")
  DISTINCT_T2_COUNT_N1=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"select count(distinct c1) from test.t2")
  DISTINCT_T2_COUNT_N2=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"select count(distinct c1) from test.t2")
  DISTINCT_T2_COUNT_N3=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"select count(distinct c1) from test.t2")
  DISTINCT_T3_COUNT_N1=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node1/node1_socket.sock -u root -Bse"select count(distinct c1) from test.t3")
  DISTINCT_T3_COUNT_N2=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node2/node2_socket.sock -u root -Bse"select count(distinct c1) from test.t3")
  DISTINCT_T3_COUNT_N3=$($BASEDIR/bin/mysql  --socket=${WORKDIR}/node3/node3_socket.sock -u root -Bse"select count(distinct c1) from test.t3")

  function output_format(){
    divider===============================
    divider=$divider$divider
    header="\n %-10s %10s %10s %10s\n"
    format=" %-10s %10d %10d %10d\n"
     
    width=43
     
    printf "$header" "tname" "n1_rows" "n2_rows" "n3_rows"
     
    printf "%$width.${width}s\n" "$divider"
     
    printf "$format" \
    t1 $DISTINCT_T1_COUNT_N1  $DISTINCT_T1_COUNT_N2 $DISTINCT_T1_COUNT_N3 \
    t2 $DISTINCT_T2_COUNT_N1  $DISTINCT_T2_COUNT_N2 $DISTINCT_T2_COUNT_N3 \
    t3 $DISTINCT_T3_COUNT_N1  $DISTINCT_T3_COUNT_N2 $DISTINCT_T3_COUNT_N3 
  }
  output_format
  echoit "Shuttingdown PXC"
  $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node3/node3_socket.sock -u root shutdown
  echoit "Server on socket ${WORKDIR}/node3/node3_socket.sock with datadir $WORKDIR/node3 halted."
  $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node2/node2_socket.sock -u root shutdown
  echoit "Server on socket ${WORKDIR}/node2/node2_socket.sock with datadir $WORKDIR/node2 halted."
  $BASEDIR/bin/mysqladmin  --socket=${WORKDIR}/node1/node1_socket.sock -u root shutdown
  echoit "Server on socket ${WORKDIR}/node1/node1_socket.sock with datadir $WORKDIR/node1 halted."
  
fi
