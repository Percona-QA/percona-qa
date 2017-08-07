#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is for PXC SSL testing
# Need to execute this script from PXC basedir

BUILD=$(pwd)
sst_method="rsync"
PS_START_TIMEOUT=60

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT * 1000 ))"

SUSER=root
SPASS=

#Kill existing mysqld process
ps -ef | grep 'n[0-9].sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

rm -rf ${BUILD}/logs/ps_ssl_testing.log &> /dev/null
echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${BUILD}" != "" ]; then echo "[$(date +'%T')] $1" >> ${BUILD}/logs/ps_ssl_testing.log; fi
}

if [ ! -r ${BUILD}/bin/mysqld ]; then  
  echoit "Please execute the script from PXC basedir"
  exit 1
fi

# Creating sysbench log directory
mkdir -p ${BUILD}/logs

archives() {
  tar czf ${BUILD}/results-${BUILD_NUMBER}.tar.gz ${BUILD}/logs || true
}

trap archives EXIT KILL

#Check command failure
check_cmd(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echoit "ERROR: $ERROR_MSG. Terminating!"; exit 1; fi
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
}

## SSL certificate generation
echoit "Creating SSL certificates"
create_certs

cd ${BUILD}

# Creating default my.cnf file
echo "[mysqld]" > my.cnf
echo "basedir=${BUILD}" >> my.cnf
echo "innodb_file_per_table" >> my.cnf
echo "core-file" >> my.cnf
echo "log-output=none" >> my.cnf
echo "ssl-ca=${BUILD}/mysql-test/std_data/percona-cacert.pem" >> my.cnf
echo "ssl-key=${BUILD}/mysql-test/std_data/percona-serversan-key.pem" >> my.cnf
echo "ssl-cert=${BUILD}/mysql-test/std_data/percona-serversan-cert.pem" >> my.cnf
echo "skip-name-resolve" >> my.cnf

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
if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${BUILD}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BUILD}"
elif [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${BUILD}/scripts/mysql_install_db --no-defaults --basedir=${BUILD}"
fi

start_ps_node(){
  i=$1
  RBASE1="$(( RBASE + ( 100 * $i ) ))"
  node="${BUILD}/node${i}"
  startup_check(){
    for X in $(seq 0 ${PS_START_TIMEOUT}); do
      sleep 1
      if ${BUILD}/bin/mysqladmin -uroot -S/tmp/n${i}.sock ping > /dev/null 2>&1; then
        echoit "Started PS node${i}. Socket : /tmp/n${i}.sock"
        break
      fi
    done
  }

  if [ "$(${BUILD}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1 )" != "5.7" ]; then
    mkdir -p $node
    if  [ ! "$(ls -A $node)" ]; then 
      ${MID} --datadir=$node  > ${BUILD}/logs/startup_node${i}.err 2>&1 || exit 1;
    fi
  fi
  if [ ! -d $node ]; then
    ${MID} --datadir=$node  > ${BUILD}/logs/startup_node${i}.err 2>&1 || exit 1;
  fi
  
  echoit "Starting PS node${i}..."
  ${BUILD}/bin/mysqld $DEFAULT_FILE \
   --datadir=$node \
   --log-error=$node/node${i}.err \
   --socket=/tmp/n${i}.sock --port=$RBASE1 > $node/node${i}.err 2>&1 &

  startup_check
  PORT=$RBASE1
  ${BUILD}/bin/mysql -uroot --socket=/tmp/n${i}.sock -e"CREATE USER 'sslsst'@'%' REQUIRE SSL;GRANT ALL ON *.* TO 'sslsst'@'%';"
}

insert_loop(){
  NUM_END=$(shuf -i ${1} -n 1)
  CONNECTION_STRING=$2
  for i in `seq 1 $NUM_END`; do
    STRING=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    ${BUILD}/bin/mysql $CONNECTION_STRING -e "INSERT INTO test.t1 (str) VALUES ('${STRING}')" 
  done
}

encryption_run(){
  TEST_START_TIME=`date '+%s'`
  DEFAULT_FILE="--defaults-file=${BUILD}/my.cnf"
  rm -rf ${BUILD}/node*
  start_ps_node $1
  ${BUILD}/bin/mysql -uroot --socket=/tmp/n1.sock -e"drop database if exists test;create database test;"
  ${BUILD}/bin/mysql -uroot --socket=/tmp/n1.sock -e"create table test.t1 (id int auto_increment,str varchar(32), primary key(id))" 2>&1
  
  #Data load
  echoit "Running  load data..."
  if [ -r  ${BUILD}/mysql-test/std_data/percona-cacert.pem ];then
    echoit "IPv4 SSL testing"
    insert_loop 100-500 "-h localhost --user=sslsst -P$PORT --ssl-mode=VERIFY_CA --ssl-ca=${BUILD}/mysql-test/std_data/percona-cacert.pem --protocol=tcp"
    insert_loop 100-500 "-h localhost --user=sslsst -P$PORT --ssl-mode=VERIFY_IDENTITY --ssl-ca=${BUILD}/mysql-test/std_data/percona-cacert.pem --protocol=tcp"
    insert_loop 100-500 "-h 127.0.0.1 --user=sslsst -P$PORT --ssl-mode=VERIFY_CA --ssl-ca=${BUILD}/mysql-test/std_data/percona-cacert.pem --protocol=tcp"
    insert_loop 100-500 "-h 127.0.0.1 --user=sslsst -P$PORT --ssl-mode=VERIFY_IDENTITY --ssl-ca=${BUILD}/mysql-test/std_data/percona-cacert.pem --protocol=tcp"
    insert_loop 100-500 "-h 127.0.0.2 --user=sslsst -P$PORT --ssl-mode=VERIFY_CA --ssl-ca=${BUILD}/mysql-test/std_data/percona-cacert.pem --protocol=tcp"
  fi
  for i in `seq 1 $1`;do
    ${BUILD}/bin/mysqladmin -uroot -S/tmp/n${i}.sock shutdown &> /dev/null
    echoit "Server on socket /tmp/n${i}.sock with datadir ${BUILD}/node$i halted"
  done
}

echoit "Starting SSL test run"
encryption_run 1
check_cmd $?
exit 0