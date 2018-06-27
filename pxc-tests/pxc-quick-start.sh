#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Quick Percona XtraDB Cluster startup script with configuration file.

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc-quick-start.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                Specify work directory"
  echo "  -b, --basedir=PATH                Specify base directory"
  echo "  -k, --keyring-plugin=[file|vault] Specify which keyring plugin to use(default keyring-file)"
  echo "  -s, --start                       Start Percona XtraDB Cluster"
  echo "  -a, --stop                        Stop Percona XtraDB Cluster"
  echo "  -r, --restart                     Restart Percona XtraDB Cluster"
  echo "  -e, --with-binlog-encryption      Run the script with binary log encryption feature"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:k:sareh --longoptions=workdir:,basedir:,start,stop,restart,keyring-plugin,with-binlog-encryption,help \
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
    -s | --start )
    shift
    export START=1
    ;;
    -a | --stop )
    shift
    export STOP=1
    ;;
    -r | --restart )
    shift
    export RESTART=1
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
if [[ -z "$BASEDIR" ]]; then
  export BASEDIR=${PWD}
fi
SCRIPT_PWD=$(cd `dirname $0` && pwd)
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

if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
elif [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
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
  	  if [[ "$KEYRING_PLUGIN" == "file" ]]; then
        echo "early-plugin-load=keyring_file.so" >> ${WORKDIR}/n${i}.cnf
        echo "keyring_file_data=$node/keyring" >> ${WORKDIR}/n${i}.cnf
      fi
	  if [[ "$KEYRING_PLUGIN" == "vault" ]]; then
        echo "early-plugin-load=\"keyring_vault=keyring_vault.so\"" >> ${WORKDIR}/n${i}.cnf
        echo "keyring_vault_config=$WORKDIR/vault/keyring_vault_pxc${i}.cnf" >> ${WORKDIR}/n${i}.cnf
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
    fi
  done
}

if [[ $START -eq 1 ]]; then
  pxc_start start
fi
if [[ $RESTART -eq 1 ]]; then
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
  echoit "Server on socket /tmp/pxc3.sock with datadir $WORKDIR/node3 halted."
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
  echoit "Server on socket /tmp/pxc2.sock with datadir $WORKDIR/node2 halted."
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
  echoit "Server on socket /tmp/pxc1.sock with datadir $WORKDIR/node1 halted."
  pxc_start restart
fi
if [[ $STOP -eq 1 ]]; then
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc3.sock -u root shutdown
  echoit "Server on socket /tmp/pxc3.sock with datadir $WORKDIR/node3 halted."
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc2.sock -u root shutdown
  echoit "Server on socket /tmp/pxc2.sock with datadir $WORKDIR/node2 halted."
  $BASEDIR/bin/mysqladmin  --socket=/tmp/pxc1.sock -u root shutdown
  echoit "Server on socket /tmp/pxc1.sock with datadir $WORKDIR/node1 halted."
fi
