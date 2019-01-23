#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is for PXC SSL testing
# Need to execute this script from PXC basedir

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "./pxc-ssl-test.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                     Specify work directory"
  echo "  -b, --build-number=NUMBER              Specify work build directory"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:s:h --longoptions=workdir:,build-number:,sst-method:,help \
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
    -s | --sst-method )
    export SST_METHOD="$2"
    shift 2
    if [[ "$SST_METHOD" != "rsync" ]] && [[ "$SST_METHOD" != "xtrabackup-v2" ]] ; then
      echo "ERROR: Invalid --sst-method passed:"
      echo "  Please choose any of these sst-method options: 'rsync' or 'xtrabackup-v2'"
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
if [[ -z "$SST_METHOD" ]]; then
  export SST_METHOD="xtrabackup-v2"
fi
if [[ -z ${BUILD_NUMBER} ]]; then
  BUILD_NUMBER=1001
fi

cd $ROOT_FS
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

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
PXCBASEDIR="${ROOT_FS}/$PXCBASE"
declare MYSQL_VERSION=$(${PXCBASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

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

# Setting xtrabackup SST method
if [[ $SST_METHOD == "xtrabackup-v2" ]];then
  PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
  if [ ! -z $PXB_BASE ];then
    export PATH="$ROOT_FS/$PXB_BASE/bin:$PATH"
  else
    if check_for_version $MYSQL_VERSION "8.0.0" ; then
      wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-8.0.4/binary/tarball/percona-xtrabackup-8.0.4-Linux-x86_64.libgcrypt20.tar.gz
    else
      wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-2.4.13/binary/tarball/percona-xtrabackup-2.4.13-Linux-x86_64.libgcrypt20.tar.gz
    fi
    tar -xzf percona-xtrabackup*.tar.gz
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$ROOT_FS/$PXB_BASE/bin:$PATH"
  fi
fi

SKIP_RQG_AND_BUILD_EXTRACT=0
NODES=2
PXC_START_TIMEOUT=300

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT * 1000 ))"

SUSER=root
SPASS=

rm -rf ${WORKDIR}/pxc_ssl_testing.log &> /dev/null
echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/pxc_ssl_testing.log; fi
}

if [ ! -r ${PXCBASEDIR}/bin/mysqld ]; then
  echoit "Please execute the script from PXC basedir"
  exit 1
fi

archives() {
  tar czf ${WORKDIR}/results-${BUILD_NUMBER}.tar.gz ${WORKDIR}/logs ${WORKDIR}/pxc_ssl_testing.log || true
}

trap archives EXIT KILL

sysbench_run(){
  TEST_TYPE="$1"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=1000 --oltp_tables_count=30 --mysql-db=test --mysql-user=root  --num-threads=30 --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=1000 --oltp_tables_count=30 --max-time=200 --report-interval=1 --max-requests=1870000000 --mysql-db=test --mysql-user=root  --num-threads=30 --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=1000 --tables=30 --mysql-db=test --mysql-user=root  --threads=30 --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=1000 --tables=30 --mysql-db=test --mysql-user=root  --threads=30 --time=200 --report-interval=1 --events=1870000000 --db-driver=mysql"
    fi
  fi
}

create_certs(){
  # Creating SSL certificate directories
  rm -rf ${WORKDIR}/certs* && mkdir -p ${WORKDIR}/certs ${WORKDIR}/certs_two && cd ${WORKDIR}/certs
  # Creating CA certificate
  echoit "Creating CA certificate"
  openssl genrsa 2048 > ca-key.pem
  openssl req -new -x509 -nodes -days 3600 -key ca-key.pem -out ca.pem -subj '/CN=www.percona.com/O=Database Performance./C=US'

  # Creating server certificate
  echoit "Creating server certificate"
  openssl req -newkey rsa:2048 -days 3600 -nodes -keyout server-key.pem -out server-req.pem -subj '/CN=www.percona.com/O=Database Performance./C=AU'
  openssl rsa -in server-key.pem -out server-key.pem
  openssl x509 -req -in server-req.pem -days 3600 -CA ca.pem -CAkey ca-key.pem -set_serial 01 -out server-cert.pem

  # Creating client certificate
  echoit "Creating client certificate"
  openssl req -newkey rsa:2048 -days 3600 -nodes -keyout client-key.pem -out client-req.pem -subj '/CN=www.percona.com/O=Database Performance./C=IN'
  openssl rsa -in client-key.pem -out client-key.pem
  openssl x509 -req -in client-req.pem -days 3600 -CA ca.pem -CAkey ca-key.pem -set_serial 01 -out client-cert.pem

  # Creating SST encryption certificates
  openssl genrsa -out sst_server.key 1024
  openssl req -new -key sst_server.key -x509 -days 3653 -out sst_server.crt -subj '/CN=www.percona.com/O=Database Performance./C=US'
  cat sst_server.key sst_server.crt > sst_server.pem
  openssl dhparam -out sst_dhparams.pem 2048
  cat sst_dhparams.pem >> sst_server.pem

  cd ${WORKDIR}/certs_two

  # Creating SST encryption certificates
  openssl genrsa -out sst_server.key 1024
  openssl req -new -key sst_server.key -x509 -days 3653 -out sst_server.crt -subj '/CN=www.percona.com/O=Database Performance blog./C=PS'
  cat sst_server.key sst_server.crt > sst_server.pem
  openssl dhparam -out sst_dhparams.pem 2048
  cat sst_dhparams.pem >> sst_server.pem
}

## SSL certificate generation
echoit "Creating SSL certificates"
create_certs

cd ${WORKDIR}

# Creating default my-template.cnf file
echo "[mysqld]" > my-template.cnf
echo "basedir=${PXCBASEDIR}" >> my-template.cnf
echo "innodb_file_per_table" >> my-template.cnf
echo "innodb_autoinc_lock_mode=2" >> my-template.cnf
echo "wsrep-provider=${PXCBASEDIR}/lib/libgalera_smm.so" >> my-template.cnf
echo "wsrep_node_incoming_address=$ADDR" >> my-template.cnf
echo "wsrep_sst_method=$SST_METHOD" >> my-template.cnf
echo "wsrep_sst_auth=$SUSER:$SPASS" >> my-template.cnf
echo "wsrep_node_address=$ADDR" >> my-template.cnf
echo "core-file" >> my-template.cnf
echo "log-output=none" >> my-template.cnf
echo "server-id=1" >> my-template.cnf
echo "wsrep_slave_threads=2" >> my-template.cnf
echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> my-template.cnf
echo "ssl-cert=${WORKDIR}/certs/server-cert.pem" >> my-template.cnf
echo "ssl-key=${WORKDIR}/certs/server-key.pem" >> my-template.cnf
echo "[client]" >> my-template.cnf
echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> my-template.cnf
echo "ssl-cert=${WORKDIR}/certs/client-cert.pem" >> my-template.cnf
echo "ssl-key=${WORKDIR}/certs/client-key.pem" >> my-template.cnf

# Ubuntu mysqld runtime provisioning
if [ "$(uname -v | grep 'Ubuntu')" != "" ]; then
  if [ "$(dpkg -l | grep 'libaio1')" == "" ]; then
    sudo apt-get install libaio1
  fi
  if [ "$(dpkg -l | grep 'libjemalloc1')" == "" ]; then
    sudo apt-get install libjemalloc1
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libssl.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libssl.so.1.0.0 /lib/x86_64-linux-gnu/libssl.so.6
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libcrypto.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libcrypto.so.1.0.0 /lib/x86_64-linux-gnu/libcrypto.so.6
  fi
fi

# Setting seeddb creation configuration
KEY_RING_CHECK=0
if check_for_version $MYSQL_VERSION "5.7.0" ; then 
  MID="${PXCBASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXCBASEDIR}"
  KEY_RING_CHECK=1
else
  MID="${PXCBASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXCBASEDIR}"
fi

start_pxc_node(){
  i=$1
  RBASE1="$(( RBASE + ( 100 * $i ) ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
  node="${WORKDIR}/node${i}"
  keyring_node="${WORKDIR}/keyring_node${i}"

  startup_check(){
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${PXCBASEDIR}/bin/mysqladmin -uroot -S/tmp/n${i}.sock ping > /dev/null 2>&1; then
        echoit "Started PXC node${i}. Socket : /tmp/n${i}.sock"
        break
      fi
    done
  }

  if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
    mkdir -p $node $keyring_node
    if  [ ! "$(ls -A $node)" ]; then
      ${MID} --datadir=$node  > ${WORKDIR}/logs/startup_node${i}.err 2>&1 || exit 1;
    fi
  fi
  if [ ! -d $node ]; then
    ${MID} --datadir=$node  > ${WORKDIR}/logs/startup_node${i}.err 2>&1 || exit 1;
  fi
  if [ $KEY_RING_CHECK -eq 1 ]; then
    KEY_RING_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=$keyring_node/keyring"
  fi
  if [ ${1} -eq 1 ]; then
    IS_NEW="--wsrep-new-cluster"
  else
    IS_NEW=""
  fi

  if [ "$SST_ENCRYPTION_OPTION" == "mysqldump_sst" ]; then
    if [ $i -eq 2 ] ;then
      echoit "Preparing PXC node${i} for mysqldump sst test..."
      ${PXCBASEDIR}/bin/mysqld $DEFAULT_FILE \
       --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
       --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${WORKDIR}/certs/server-key.pem;socket.ssl_cert=${WORKDIR}/certs/server-cert.pem;socket.ssl_ca=${WORKDIR}/certs/ca.pem" \
       --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
       --socket=/tmp/n${i}.sock --port=$RBASE1 --wsrep_provider=none --wsrep_sst_method=mysqldump --wsrep_sst_auth=sslsst: > $node/node${i}.err 2>&1 &

      startup_check

      ${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/n${i}.sock -e"CREATE USER 'sslsst'@'%' REQUIRE SSL;GRANT ALL ON *.* TO 'sslsst'@'%';"

      ${PXCBASEDIR}/bin/mysqladmin -uroot -S/tmp/n${i}.sock shutdown &> /dev/null

      echoit "Starting PXC node${i} for mysqldump sst test..."
      ${PXCBASEDIR}/bin/mysqld $DEFAULT_FILE \
       --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
       --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${WORKDIR}/certs/server-key.pem;socket.ssl_cert=${WORKDIR}/certs/server-cert.pem;socket.ssl_ca=${WORKDIR}/certs/ca.pem" \
       --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
       --socket=/tmp/n${i}.sock --port=$RBASE1 --wsrep_sst_method=mysqldump --wsrep_sst_auth=sslsst: > $node/node${i}.err 2>&1 &

      startup_check
    else
      echoit "Starting PXC node${i}..."
      ${PXCBASEDIR}/bin/mysqld $DEFAULT_FILE \
       --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
       --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${WORKDIR}/certs/server-key.pem;socket.ssl_cert=${WORKDIR}/certs/server-cert.pem;socket.ssl_ca=${WORKDIR}/certs/ca.pem" \
       --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
       --socket=/tmp/n${i}.sock --port=$RBASE1 --wsrep_sst_method=mysqldump --wsrep_sst_auth=sslsst: > $node/node${i}.err 2>&1 &

      startup_check
      ${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/n${i}.sock -e"CREATE USER 'sslsst'@'%' REQUIRE SSL;GRANT ALL ON *.* TO 'sslsst'@'%';"

    fi
  else
    echoit "Starting PXC node${i}..."
    ${PXCBASEDIR}/bin/mysqld $DEFAULT_FILE \
     --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
     --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${WORKDIR}/certs/server-key.pem;socket.ssl_cert=${WORKDIR}/certs/server-cert.pem;socket.ssl_ca=${WORKDIR}/certs/ca.pem" \
     --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
     --socket=/tmp/n${i}.sock --port=$RBASE1 > $node/node${i}.err 2>&1 &
     startup_check
  fi
}

sst_encryption_run(){
  SST_ENCRYPTION_OPTION=$1
  SST_SHUFFLE_CERT=$2
  TEST_START_TIME=`date '+%s'`
  cp ${WORKDIR}/my-template.cnf ${WORKDIR}/my.cnf
  if [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_encrypt" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 1" >> my.cnf
    echo "encrypt-algo=AES256" >> my.cnf
    echo "encrypt-key=A1EDC73815467C083B0869508406637E" >> my.cnf
    DEFAULT_FILE="--defaults-file=${WORKDIR}/my.cnf"
  elif [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_tca" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 2" >> my.cnf
    echo "tcert=${WORKDIR}/certs/sst_server.pem" >> my.cnf
    echo "tca=${WORKDIR}/certs/sst_server.crt" >> my.cnf
    DEFAULT_FILE="--defaults-file=${WORKDIR}/my.cnf"
  elif [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_tkey" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 3" >> my.cnf
    echo "tkey=${WORKDIR}/certs/sst_server.key" >> my.cnf
    echo "tcert=${WORKDIR}/certs/sst_server.pem" >> my.cnf
    DEFAULT_FILE="--defaults-file=${WORKDIR}/my.cnf"
  elif [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_native_key" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 4" >> my.cnf
    echo "ssl-ca=${WORKDIR}/certs/ca.pem" >> my.cnf
    echo "ssl-cert=${WORKDIR}/certs/server-cert.pem" >> my.cnf
    echo "ssl-key=${WORKDIR}/certs/server-key.pem" >> my.cnf
    DEFAULT_FILE="--defaults-file=${WORKDIR}/my.cnf"
  else
    DEFAULT_FILE="--defaults-file=${WORKDIR}/my.cnf"
  fi

  rm -rf ${WORKDIR}/node* ${WORKDIR}/keyring_node*
  start_pxc_node 1

  ${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/n1.sock -e"drop database if exists test;create database test;"

  #sysbench data load
  echoit "Running sysbench load data..."
  sysbench_run load_data
  sysbench $SYSBENCH_OPTIONS --mysql-socket=/tmp/n1.sock prepare > ${WORKDIR}/logs/sysbench_load.log 2>&1

  start_pxc_node 2

  echoit "Initiated sysbench read write run ..."
  sysbench_run oltp
  sysbench $SYSBENCH_OPTIONS --mysql-socket=/tmp/n1.sock run > ${WORKDIR}/logs/sysbench_rw_run.log 2>&1
  TEST_TIME=$((`date '+%s'` - TEST_START_TIME))
  sleep 10
  TABLE_ROW_COUNT_NODE1=`${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/n1.sock -Bse"select count(1) from test.sbtest11"`
  TABLE_ROW_COUNT_NODE2=`${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/n2.sock -Bse"select count(1) from test.sbtest11"`

  if  [[ ( -z $TABLE_ROW_COUNT_NODE1 ) &&  (  -z $TABLE_ROW_COUNT_NODE2 ) ]] ;then
    TABLE_ROW_COUNT_NODE1=1;
    TABLE_ROW_COUNT_NODE2=2;
  fi

  echo $SST_SHUFFLE_CERT
  if [ ! -z $SST_SHUFFLE_CERT ];then
    cp ${WORKDIR}/my-template.cnf ${WORKDIR}/my_shuffle.cnf
    echo "[sst]" >> my_shuffle.cnf
    echo "encrypt = 3" >> my_shuffle.cnf
    echo "tkey=${WORKDIR}/certs_two/sst_server.key" >> my_shuffle.cnf
    echo "tcert=${WORKDIR}/certs_two/sst_server.pem" >> my_shuffle.cnf
    DEFAULT_FILE="--defaults-file=${WORKDIR}/my_shuffle.cnf"
    start_pxc_node 3
    NODES=3
  fi
  for i in `seq 1 $NODES`;do
    ${PXCBASEDIR}/bin/mysqladmin -uroot -S/tmp/n${i}.sock shutdown &> /dev/null
    echoit "Server on socket /tmp/n${i}.sock with datadir ${WORKDIR}/node$i halted"
  done
}

test_result(){
  TEST_NAME=$1
  printf "%-82s\n" | tr " " "="
  printf "%-60s  %-10s  %-10s\n" "TEST" " RESULT" "TIME(s)"
  printf "%-82s\n" | tr " " "-"
  if [ "$TABLE_ROW_COUNT_NODE1" == "$TABLE_ROW_COUNT_NODE2" ]; then
    printf "%-60s  %-10s  %-10s\n" "$TEST_NAME" "[passed]" "$TEST_TIME"
  else
    printf "%-60s  %-10s  %-10s\n" "$TEST_NAME" "[failed]" "$TEST_TIME"
  fi
  printf "%-82s\n" | tr " " "="
}

if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
  echoit "Starting SST test using mysqldump"
  sst_encryption_run mysqldump_sst
  test_result "mysqldump SST"
fi
echoit "Starting SST test using xtrabackup with encryption key"
sst_encryption_run xtrabackup_encrypt
test_result "xtrabackup SST (encryption key)"

echoit "Starting SST test using xtrabackup with certificate authority and certificate files"
sst_encryption_run xtrabackup_tca
test_result "xtrabackup SST (certificate authority and certificate files)"

echoit "Starting SST test using xtrabackup with key and certificate files"
sst_encryption_run xtrabackup_tkey
test_result "xtrabackup SST (key and certificate files)"

echoit "Starting SST test using xtrabackup with MySQL-generated SSL files"
sst_encryption_run xtrabackup_native_key
test_result "xtrabackup SST (using MySQL-generated SSL files)"

echoit "Starting SST test with different key and certificate files"
sst_encryption_run xtrabackup_tkey shuffle_test
test_result "xtrabackup SST with different key and certificate files"

exit 0
