#!/bin/bash

if [ $# -eq 0 ]; then
  echo "No arguments passed. Exiting"
  exit 1
fi

BASEDIR=$(realpath $1)
PXC_START_TIMEOUT=60

echo "Killing any previous running mysqld server"
pkill -9 mysqld

echo "BaseDir has been set to: $BASEDIR";

if [ -d $BASEDIR/pxc-node ]; then
  echo "Found existing PXC nodes."
  rm -irf $BASEDIR/pxc-node
fi

echo "Creating work directory"
WORKDIR=$BASEDIR/pxc-node
mkdir $WORKDIR
mkdir $WORKDIR/cert
mkdir $WORKDIR/keyring_holder
echo "Workdir has been set to: $WORKDIR" 
SOCKET1=$BASEDIR/pxc-node/dn1/mysqld.sock
SOCKET2=$BASEDIR/pxc-node/dn2/mysqld.sock
ERR_FILE1=$BASEDIR/pxc-node/node1.err
ERR_FILE2=$BASEDIR/pxc-node/node2.err

echo "Creating n1.cnf"
echo "
[mysqld]

port = 4000
server-id=1
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR/
datadir=$BASEDIR/pxc-node/dn1
plugin_dir=$BASEDIR/lib/plugin/
log-error=$BASEDIR/pxc-node/node1.err
general_log=1
general_log_file=$BASEDIR/pxc-node/dn1/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR/pxc-node/dn1/slow.log
socket=$SOCKET1
character-sets-dir=$BASEDIR/share/charsets
lc-messages-dir=$BASEDIR/share/

# pxc variables
log_bin=binlog
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
binlog_encryption=ON
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:5030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;gcache.encryption=ON;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node4000
innodb_autoinc_lock_mode=2

# Due to Bug PXC-4116 and PXC-4173, disabling parallel workers
replica_parallel_workers=1

early-plugin-load=keyring_file.so
keyring_file_data=$WORKDIR/dn1/keyring_holder/keyring1
ssl-ca = $WORKDIR/cert/ca.pem
ssl-cert = $WORKDIR/cert/server-cert.pem
ssl-key = $WORKDIR/cert/server-key.pem
[client]
ssl-ca = $WORKDIR/cert/ca.pem
ssl-cert = $WORKDIR/cert/client-cert.pem
ssl-key = $WORKDIR/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR/cert/ca.pem
ssl-cert = $WORKDIR/cert/server-cert.pem
ssl-key = $WORKDIR/cert/server-key.pem


" > $WORKDIR/n1.cnf

echo "Creating n2.cnf"
echo "
[mysqld]

port = 5000
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR/
datadir=$BASEDIR/pxc-node/dn2
plugin_dir=$BASEDIR/lib/plugin
log-error=$BASEDIR/pxc-node/node2.err
general_log=1
general_log_file=$BASEDIR/pxc-node/dn2/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR/pxc-node/dn2/slow.log
socket=$SOCKET2
character-sets-dir=$BASEDIR/share/charsets
lc-messages-dir=$BASEDIR/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
binlog_encryption=ON
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:4030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:5020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;gcache.encryption=ON;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node5000
innodb_autoinc_lock_mode=2
# Due to Bug PXC-4116 and PXC-4173, disabling parallel workers
replica_parallel_workers=1

early-plugin-load=keyring_file.so
keyring_file_data=$WORKDIR/dn1/keyring_holder/keyring2
ssl-ca = $WORKDIR/cert/ca.pem
ssl-cert = $WORKDIR/cert/server-cert.pem
ssl-key = $WORKDIR/cert/server-key.pem
[client]
ssl-ca = $WORKDIR/cert/ca.pem
ssl-cert = $WORKDIR/cert/client-cert.pem
ssl-key = $WORKDIR/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR/cert/ca.pem
ssl-cert = $WORKDIR/cert/server-cert.pem
ssl-key = $WORKDIR/cert/server-key.pem

" > $WORKDIR/n2.cnf

fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    SOCKET=$SOCKET1
    ERR_FILE=$ERR_FILE1
  elif [ $NR -eq 2 ]; then
    SOCKET=$SOCKET2
    ERR_FILE=$ERR_FILE2
  fi
}

pxc_startup_status(){
  NR=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET} ping > /dev/null 2>&1; then
      echo "Node$NR started successfully"
      break
    fi
    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
	    echo "Node$NR failed to start. Exiting"
	    exit 1
    fi
  done
}

echo "Creating data directories"
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn1 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node1.err 
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn2 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node2.err
echo "Data directory created"

cp ${WORKDIR}/dn1/*.pem ${WORKDIR}/cert/
cp ${WORKDIR}/dn2/*.pem ${WORKDIR}/cert/

echo "Starting PXC nodes..."
fetch_err_socket 1
$BASEDIR/bin/mysqld --defaults-file=$BASEDIR/pxc-node/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
pxc_startup_status 1

fetch_err_socket 2
$BASEDIR/bin/mysqld --defaults-file=$BASEDIR/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

echo "Checking 2 node PXC Cluster startup..."
for X in $(seq 0 2); do
  sleep 5 
  CLUSTER_UP=0;
  if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET1} ping > /dev/null 2>&1; then
    if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET2} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET2} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
  fi
  # If count reached 4 (there are 4 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 4 ]; then
    echo "2 Node PXC Cluster started ok. Clients:"
    echo "Node #1: `echo ${BASEDIR}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET1}"
    echo "Node #2: `echo ${BASEDIR}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET2}"
    break
  fi
done

echo "Creating datadir for async node 3"
$BASEDIR/bin/mysqld --no-defaults --datadir=${WORKDIR}/dn3 --initialize-insecure --log-error=${WORKDIR}/node3.err

echo "Starting node 3"
$BASEDIR/bin/mysqld --no-defaults --datadir=${WORKDIR}/dn3 --port=22000 --socket=/tmp/mysql_22000.sock --plugin-dir=$BASEDIR/lib/plugin --early-plugin-load=keyring_file.so --keyring_file_data=${WORKDIR}/dn3/mykey --max-connections=1024 --log-error --general-log --log-error-verbosity=3 --core-file --server_id=3 --gtid_mode=ON --enforce_gtid_consistency=ON &

sleep 5;

echo "Node #3: `echo ${BASEDIR}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S/tmp/mysql_22000.sock"

fetch_err_socket 1
${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"CHANGE REPLICATION SOURCE TO SOURCE_HOST='127.0.0.1', SOURCE_PORT=22000,SOURCE_USER='root'"
${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"START REPLICA"

