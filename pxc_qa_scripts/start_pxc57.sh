#!/bin/bash

BASEDIR=$(realpath $1)
PXC_START_TIMEOUT=60

echo "BaseDir has been set to: $BASEDIR";

if [ -d $BASEDIR/pxc-node ]; then
  echo "Found existing PXC nodes."
  rm -irf $BASEDIR/pxc-node
fi

echo "Creating work directory"
WORKDIR=$BASEDIR/pxc-node
mkdir $WORKDIR
mkdir $WORKDIR/cert
echo "Workdir has been set to: $WORKDIR" 
SOCKET1=$BASEDIR/pxc-node/dn1/mysqld.sock
SOCKET2=$BASEDIR/pxc-node/dn2/mysqld.sock
SOCKET3=$BASEDIR/pxc-node/dn3/mysqld.sock
ERR_FILE1=$BASEDIR/pxc-node/node1.err
ERR_FILE2=$BASEDIR/pxc-node/node2.err
ERR_FILE3=$BASEDIR/pxc-node/node3.err

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
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_sst_auth=root:
wsrep_cluster_address='gcomm://127.0.0.1:5030,127.0.0.1:6030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node4000
innodb_autoinc_lock_mode=2

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
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_sst_auth=root:
wsrep_cluster_address='gcomm://127.0.0.1:4030,127.0.0.1:6030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:5020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node5000
innodb_autoinc_lock_mode=2

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

echo "Creating n3.cnf"
echo "
[mysqld]

port = 6000
server-id=3
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR/
datadir=$BASEDIR/pxc-node/dn3
plugin_dir=$BASEDIR/lib/plugin
log-error=$BASEDIR/pxc-node/node3.err
general_log=1
general_log_file=$BASEDIR/pxc-node/dn3/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR/pxc-node/dn3/slow.log
socket=$SOCKET3
character-sets-dir=$BASEDIR/share/charsets
lc-messages-dir=$BASEDIR/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=ON

# wsrep variables
wsrep_sst_auth=root:
wsrep_cluster_address='gcomm://127.0.0.1:4030,127.0.0.1:5030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:6020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_debug=1
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:6030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node6000
innodb_autoinc_lock_mode=2

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

" > $WORKDIR/n3.cnf

fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    SOCKET=$SOCKET1
    ERR_FILE=$ERR_FILE1
  elif [ $NR -eq 2 ]; then
    SOCKET=$SOCKET2
    ERR_FILE=$ERR_FILE2
  elif [ $NR -eq 3 ]; then
    SOCKET=$SOCKET3
    ERR_FILE=$ERR_FILE3
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
  done
}

echo "Creating data directories"
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn1 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node1.err 
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn2 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node2.err
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn3 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node3.err
echo "Data directory created"

cp ${WORKDIR}/dn1/*.pem ${WORKDIR}/cert/
cp ${WORKDIR}/dn2/*.pem ${WORKDIR}/cert/
cp ${WORKDIR}/dn3/*.pem ${WORKDIR}/cert/

echo "Starting PXC nodes..."
fetch_err_socket 1
$BASEDIR/bin/mysqld --defaults-file=$BASEDIR/pxc-node/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
pxc_startup_status 1

fetch_err_socket 2
$BASEDIR/bin/mysqld --defaults-file=$BASEDIR/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

fetch_err_socket 3
$BASEDIR/bin/mysqld --defaults-file=$BASEDIR/pxc-node/n3.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 3

echo "Checking 3 node PXC Cluster startup..."
for X in $(seq 0 10); do
  sleep 1
  CLUSTER_UP=0;
  if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET1} ping > /dev/null 2>&1; then
    if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET2} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET3} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET2} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET3} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
  fi
  # If count reached 6 (there are 6 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 6 ]; then
    echo "3 Node PXC Cluster started ok. Clients:"
    echo "Node #1: `echo ${BASEDIR}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET1}"
    echo "Node #2: `echo ${BASEDIR}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET2}"
    echo "Node #3: `echo ${BASEDIR}/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET3}"
    break
  fi
done
