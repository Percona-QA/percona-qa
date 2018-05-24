#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is for PXC SSL testing
# Need to execute this script from PXC basedir

BUILD=$(pwd)
SKIP_RQG_AND_BUILD_EXTRACT=0
sst_method="rsync"
NODES=2
PXC_START_TIMEOUT=300

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT * 1000 ))"

SUSER=root
SPASS=

rm -rf ${BUILD}/pxc_ssl_testing.log &> /dev/null
echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${BUILD}" != "" ]; then echo "[$(date +'%T')] $1" >> ${BUILD}/pxc_ssl_testing.log; fi
}

if [ ! -r ${BUILD}/bin/mysqld ]; then
  echoit "Please execute the script from PXC basedir"
  exit 1
fi

# Creating sysbench log directory
mkdir -p ${BUILD}/logs
#rm -rf ${BUILD}/certs && mkdir -p ${BUILD}/certs && cd ${BUILD}/certs

archives() {
  tar czf ${BUILD}/results-${BUILD_NUMBER}.tar.gz ${BUILD}/logs ${BUILD}/pxc_ssl_testing.log || true
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
  rm -rf ${BUILD}/certs* && mkdir -p ${BUILD}/certs ${BUILD}/certs_two && cd ${BUILD}/certs
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

  cd ${BUILD}/certs_two

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

cd ${BUILD}

# Creating default my-template.cnf file
echo "[mysqld]" > my-template.cnf
echo "basedir=${BUILD}" >> my-template.cnf
echo "innodb_file_per_table" >> my-template.cnf
echo "innodb_autoinc_lock_mode=2" >> my-template.cnf
echo "innodb_locks_unsafe_for_binlog=1" >> my-template.cnf
echo "wsrep-provider=${BUILD}/lib/libgalera_smm.so" >> my-template.cnf
echo "wsrep_node_incoming_address=$ADDR" >> my-template.cnf
echo "wsrep_sst_method=xtrabackup-v2" >> my-template.cnf
echo "wsrep_sst_auth=$SUSER:$SPASS" >> my-template.cnf
echo "wsrep_node_address=$ADDR" >> my-template.cnf
echo "core-file" >> my-template.cnf
echo "log-output=none" >> my-template.cnf
echo "server-id=1" >> my-template.cnf
echo "wsrep_slave_threads=2" >> my-template.cnf
echo "ssl-ca=${BUILD}/certs/ca.pem" >> my-template.cnf
echo "ssl-cert=${BUILD}/certs/server-cert.pem" >> my-template.cnf
echo "ssl-key=${BUILD}/certs/server-key.pem" >> my-template.cnf
echo "[client]" >> my-template.cnf
echo "ssl-ca=${BUILD}/certs/ca.pem" >> my-template.cnf
echo "ssl-cert=${BUILD}/certs/client-cert.pem" >> my-template.cnf
echo "ssl-key=${BUILD}/certs/client-key.pem" >> my-template.cnf

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

# Setting xtrabackup SST method
if [[ $sst_method == "xtrabackup" ]];then
  PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
  if [ ! -z $PXB_BASE ];then
    export PATH="$BUILD/$PXB_BASE/bin:$PATH"
  else
    wget http://jenkins.percona.com/job/percona-xtrabackup-2.4-binary-tarball/label_exp=centos5-64/lastSuccessfulBuild/artifact/*zip*/archive.zip
    unzip archive.zip
    tar -xzf archive/TARGET/*.tar.gz
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$BUILD/$PXB_BASE/bin:$PATH"
  fi
fi

# Setting seeddb creation configuration
KEY_RING_CHECK=0
if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BUILD}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BUILD}"
  KEY_RING_CHECK=1
elif [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BUILD}/scripts/mysql_install_db --no-defaults --basedir=${BUILD}"
fi

start_pxc_node(){
  i=$1
  RBASE1="$(( RBASE + ( 100 * $i ) ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"
  WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
  node="${BUILD}/node${i}"
  keyring_node="${BUILD}/keyring_node${i}"

  startup_check(){
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${BUILD}/bin/mysqladmin -uroot -S/tmp/n${i}.sock ping > /dev/null 2>&1; then
        echoit "Started PXC node${i}. Socket : /tmp/n${i}.sock"
        break
      fi
    done
  }

  if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
    mkdir -p $node $keyring_node
    if  [ ! "$(ls -A $node)" ]; then
      ${MID} --datadir=$node  > ${BUILD}/logs/startup_node${i}.err 2>&1 || exit 1;
    fi
  fi
  if [ ! -d $node ]; then
    ${MID} --datadir=$node  > ${BUILD}/logs/startup_node${i}.err 2>&1 || exit 1;
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
      ${BUILD}/bin/mysqld $DEFAULT_FILE \
       --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
       --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${BUILD}/certs/server-key.pem;socket.ssl_cert=${BUILD}/certs/server-cert.pem;socket.ssl_ca=${BUILD}/certs/ca.pem" \
       --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
       --socket=/tmp/n${i}.sock --port=$RBASE1 --wsrep_provider=none --wsrep_sst_method=mysqldump --wsrep_sst_auth=sslsst: > $node/node${i}.err 2>&1 &

      startup_check

      ${BUILD}/bin/mysql -uroot --socket=/tmp/n${i}.sock -e"CREATE USER 'sslsst'@'%' REQUIRE SSL;GRANT ALL ON *.* TO 'sslsst'@'%';"

      ${BUILD}/bin/mysqladmin -uroot -S/tmp/n${i}.sock shutdown &> /dev/null

      echoit "Starting PXC node${i} for mysqldump sst test..."
      ${BUILD}/bin/mysqld $DEFAULT_FILE \
       --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
       --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${BUILD}/certs/server-key.pem;socket.ssl_cert=${BUILD}/certs/server-cert.pem;socket.ssl_ca=${BUILD}/certs/ca.pem" \
       --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
       --socket=/tmp/n${i}.sock --port=$RBASE1 --wsrep_sst_method=mysqldump --wsrep_sst_auth=sslsst: > $node/node${i}.err 2>&1 &

      startup_check
    else
      echoit "Starting PXC node${i}..."
      ${BUILD}/bin/mysqld $DEFAULT_FILE \
       --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
       --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${BUILD}/certs/server-key.pem;socket.ssl_cert=${BUILD}/certs/server-cert.pem;socket.ssl_ca=${BUILD}/certs/ca.pem" \
       --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
       --socket=/tmp/n${i}.sock --port=$RBASE1 --wsrep_sst_method=mysqldump --wsrep_sst_auth=sslsst: > $node/node${i}.err 2>&1 &

      startup_check
      ${BUILD}/bin/mysql -uroot --socket=/tmp/n${i}.sock -e"CREATE USER 'sslsst'@'%' REQUIRE SSL;GRANT ALL ON *.* TO 'sslsst'@'%';"

    fi
  else
    echoit "Starting PXC node${i}..."
    ${BUILD}/bin/mysqld $DEFAULT_FILE \
     --datadir=$node $IS_NEW --wsrep_cluster_address=$WSREP_CLUSTER \
     --wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1;socket.ssl_key=${BUILD}/certs/server-key.pem;socket.ssl_cert=${BUILD}/certs/server-cert.pem;socket.ssl_ca=${BUILD}/certs/ca.pem" \
     --log-error=$node/node${i}.err $KEY_RING_OPTIONS \
     --socket=/tmp/n${i}.sock --port=$RBASE1 > $node/node${i}.err 2>&1 &
     startup_check
  fi

}

sst_encryption_run(){
  SST_ENCRYPTION_OPTION=$1
  SST_SHUFFLE_CERT=$2
  TEST_START_TIME=`date '+%s'`
  cp ${BUILD}/my-template.cnf ${BUILD}/my.cnf
  if [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_encrypt" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 1" >> my.cnf
    echo "encrypt-algo=AES256" >> my.cnf
    echo "encrypt-key=A1EDC73815467C083B0869508406637E" >> my.cnf
    DEFAULT_FILE="--defaults-file=${BUILD}/my.cnf"
  elif [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_tca" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 2" >> my.cnf
    echo "tcert=${BUILD}/certs/sst_server.pem" >> my.cnf
    echo "tca=${BUILD}/certs/sst_server.crt" >> my.cnf
    DEFAULT_FILE="--defaults-file=${BUILD}/my.cnf"
  elif [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_tkey" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 3" >> my.cnf
    echo "tkey=${BUILD}/certs/sst_server.key" >> my.cnf
    echo "tcert=${BUILD}/certs/sst_server.pem" >> my.cnf
    DEFAULT_FILE="--defaults-file=${BUILD}/my.cnf"
  elif [ "$SST_ENCRYPTION_OPTION" == "xtrabackup_native_key" ]; then
    echo "[sst]" >> my.cnf
    echo "encrypt = 4" >> my.cnf
    echo "ssl-ca=${BUILD}/certs/ca.pem" >> my.cnf
    echo "ssl-cert=${BUILD}/certs/server-cert.pem" >> my.cnf
    echo "ssl-key=${BUILD}/certs/server-key.pem" >> my.cnf
    DEFAULT_FILE="--defaults-file=${BUILD}/my.cnf"
  else
    DEFAULT_FILE="--defaults-file=${BUILD}/my.cnf"
  fi

  rm -rf ${BUILD}/node* ${BUILD}/keyring_node*
  start_pxc_node 1

  ${BUILD}/bin/mysql -uroot --socket=/tmp/n1.sock -e"drop database if exists test;create database test;"

  #sysbench data load
  echoit "Running sysbench load data..."
  sysbench_run load_data
  sysbench $SYSBENCH_OPTIONS --mysql-socket=/tmp/n1.sock prepare > ${BUILD}/logs/sysbench_load.log 2>&1

  start_pxc_node 2

  echoit "Initiated sysbench read write run ..."
  sysbench_run oltp
  sysbench $SYSBENCH_OPTIONS --mysql-socket=/tmp/n1.sock run > ${BUILD}/logs/sysbench_rw_run.log 2>&1 &
  SYSBENCH_PID="$!"

  sleep 100
  kill -9 $SYSBENCH_PID
  wait ${SYSBENCH_PID} 2>/dev/null
  TEST_TIME=$((`date '+%s'` - TEST_START_TIME))

  TABLE_ROW_COUNT_NODE1=`${BUILD}/bin/mysql -uroot --socket=/tmp/n1.sock -e"select count(1) from test.sbtest11"`
  TABLE_ROW_COUNT_NODE2=`${BUILD}/bin/mysql -uroot --socket=/tmp/n2.sock -e"select count(1) from test.sbtest11"`

  if  [[ ( -z $TABLE_ROW_COUNT_NODE1 ) &&  (  -z $TABLE_ROW_COUNT_NODE2 ) ]] ;then
    TABLE_ROW_COUNT_NODE1=1;
    TABLE_ROW_COUNT_NODE2=2;
  fi

  echo $SST_SHUFFLE_CERT
  if [ ! -z $SST_SHUFFLE_CERT ];then
    cp ${BUILD}/my-template.cnf ${BUILD}/my_shuffle.cnf
    echo "[sst]" >> my_shuffle.cnf
    echo "encrypt = 3" >> my_shuffle.cnf
    echo "tkey=${BUILD}/certs_two/sst_server.key" >> my_shuffle.cnf
    echo "tcert=${BUILD}/certs_two/sst_server.pem" >> my_shuffle.cnf
    DEFAULT_FILE="--defaults-file=${BUILD}/my_shuffle.cnf"
    start_pxc_node 3
    NODES=3
  fi
  for i in `seq 1 $NODES`;do
    ${BUILD}/bin/mysqladmin -uroot -S/tmp/n${i}.sock shutdown &> /dev/null
    echoit "Server on socket /tmp/n${i}.sock with datadir ${BUILD}/node$i halted"
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

echoit "Starting SST test using mysqldump"
sst_encryption_run mysqldump_sst
test_result "mysqldump SST"
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

