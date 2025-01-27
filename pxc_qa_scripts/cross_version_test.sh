#!/bin/bash

BASEDIR_57=$1
BASEDIR_80=$2
PXC_START_TIMEOUT=60

echo "Basedir 57 has been set to: $BASEDIR_57";
echo "Basedir 80 has been set to: $BASEDIR_80";

if [ -d $BASEDIR_57/pxc-node ]; then
  echo "Found existing PXC nodes."
  rm -irf $BASEDIR_57/pxc-node
fi

if [ -d $BASEDIR_80/pxc-node ]; then
  echo "Found existing PXC nodes."
  rm -irf $BASEDIR_80/pxc-node
fi

for X in $(seq 1 2); do
  echo "Creating work directory for $X"
  if [ $X -eq 1 ]; then
    WORKDIR_57=$BASEDIR_57/pxc-node
    mkdir $WORKDIR_57
    mkdir $WORKDIR_57/cert
    echo "Workdir has been set to: $WORKDIR_57" 
  else
    WORKDIR_80=$BASEDIR_80/pxc-node
    mkdir $WORKDIR_80
    mkdir $WORKDIR_80/cert
    echo "Workdir has been set to: $WORKDIR_80" 
  fi
  if [ $X -eq 1 ]; then
    SOCKET_57=$BASEDIR_57/pxc-node/dn_57/mysqld_57.sock
    ERR_FILE_57=$BASEDIR_57/pxc-node/node1.err
  else
    SOCKET_80=$BASEDIR_80/pxc-node/dn_80/mysqld_80.sock
    ERR_FILE_80=$BASEDIR_80/pxc-node/node2.err
  fi
done

echo "Creating n1.cnf"
echo "
[mysqld]

port = 4000
server-id=1
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR_57/
datadir=$BASEDIR_57/pxc-node/dn_57
plugin_dir=$BASEDIR_57/lib/plugin/
log-error=$BASEDIR_57/pxc-node/node1.err
general_log=1
general_log_file=$BASEDIR_57/pxc-node/dn_57/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR_57/pxc-node/dn_57/slow.log
socket=$SOCKET_57
character-sets-dir=$BASEDIR_57/share/charsets
lc-messages-dir=$BASEDIR_57/share/

# pxc variables
log_bin=binlog
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=OFF

# wsrep variables
wsrep_sst_auth=root:
wsrep_cluster_address='gcomm://127.0.0.1:5030'
wsrep_provider=$BASEDIR_57/../../percona-xtradb-cluster-galera/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node4000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR_57/cert/ca.pem
ssl-cert = $WORKDIR_57/cert/server-cert.pem
ssl-key = $WORKDIR_57/cert/server-key.pem
[client]
ssl-ca = $WORKDIR_57/cert/ca.pem
ssl-cert = $WORKDIR_57/cert/client-cert.pem
ssl-key = $WORKDIR_57/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR_57/cert/ca.pem
ssl-cert = $WORKDIR_57/cert/server-cert.pem
ssl-key = $WORKDIR_57/cert/server-key.pem


" > $WORKDIR_57/n1.cnf

echo "Creating n2.cnf"
echo "
[mysqld]

port = 5000
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR_80/
datadir=$BASEDIR_80/pxc-node/dn_80
plugin_dir=$BASEDIR_80/lib/plugin
log-error=$BASEDIR_80/pxc-node/node2.err
general_log=1
general_log_file=$BASEDIR_80/pxc-node/dn_80/general.log
slow_query_log=1
slow_query_log_file=$BASEDIR_80/pxc-node/dn_80/slow.log
socket=$SOCKET_80
character-sets-dir=$BASEDIR_80/share/charsets
lc-messages-dir=$BASEDIR_80/share/

# pxc variables
binlog_format=ROW
gtid_mode=ON
enforce_gtid_consistency=ON
master_verify_checksum=on
binlog_checksum=CRC32
pxc_encrypt_cluster_traffic=OFF

# wsrep variables
wsrep_cluster_address='gcomm://127.0.0.1:4030'
wsrep_provider=$BASEDIR_80/../../percona-xtradb-cluster-galera/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:5020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;\"
wsrep_sst_method=xtrabackup-v2
wsrep_node_name=node5000
innodb_autoinc_lock_mode=2

ssl-ca = $WORKDIR_80/cert/ca.pem
ssl-cert = $WORKDIR_80/cert/server-cert.pem
ssl-key = $WORKDIR_80/cert/server-key.pem
[client]
ssl-ca = $WORKDIR_80/cert/ca.pem
ssl-cert = $WORKDIR_80/cert/client-cert.pem
ssl-key = $WORKDIR_80/cert/client-key.pem
[sst]
encrypt = 4
ssl-ca = $WORKDIR_80/cert/ca.pem
ssl-cert = $WORKDIR_80/cert/server-cert.pem
ssl-key = $WORKDIR_80/cert/server-key.pem

" > $WORKDIR_80/n2.cnf

fetch_err_socket() {
  NR=$1
  if [ $NR -eq 1 ]; then
    SOCKET=$SOCKET_57
    ERR_FILE=$ERR_FILE_57
  else
    SOCKET=$SOCKET_80
    ERR_FILE=$ERR_FILE_80
  fi
}

pxc_startup_status(){
  NR=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if [ $NR -eq 1 ]; then
      if $BASEDIR_57/bin/mysqladmin -uroot -S$SOCKET_57 ping > /dev/null 2>&1; then
        echo "Node started successfully"
        break
      fi
    else
      if $BASEDIR_80/bin/mysqladmin -uroot -S$SOCKET_80 ping > /dev/null 2>&1; then
        echo "Node started successfully"
        break
      fi
    fi
  done
}

echo "Creating data directories"
$BASEDIR_57/bin/mysqld --no-defaults --datadir=$BASEDIR_57/pxc-node/dn_57 --basedir=$BASEDIR_57 --initialize-insecure --log-error=$BASEDIR_57/pxc-node/node1.err 
$BASEDIR_80/bin/mysqld --no-defaults --datadir=$BASEDIR_80/pxc-node/dn_80 --basedir=$BASEDIR_80 --initialize-insecure --log-error=$BASEDIR_80/pxc-node/node2.err
echo "Data directory created"

cp $WORKDIR_57/dn_57/*.pem $WORKDIR_57/cert/
cp $WORKDIR_80/dn_80/*.pem $WORKDIR_80/cert/

echo "Starting PXC nodes..."
fetch_err_socket 1
$BASEDIR_57/bin/mysqld --defaults-file=$BASEDIR_57/pxc-node/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
pxc_startup_status 1

fetch_err_socket 2
$BASEDIR_80/bin/mysqld --defaults-file=$BASEDIR_80/pxc-node/n2.cnf > ${ERR_FILE} 2>&1 &
pxc_startup_status 2

echo "Checking 2 node PXC Cluster startup..."
for X in $(seq 0 10); do
  sleep 1
  CLUSTER_UP=0;
  if $BASEDIR_57/bin/mysqladmin -uroot -S$SOCKET_57 ping > /dev/null 2>&1; then
    if [ `$BASEDIR_57/bin/mysql -uroot -S$SOCKET_57 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ `$BASEDIR_80/bin/mysql -uroot -S$SOCKET_80 -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 2 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`$BASEDIR_57/bin/mysql -uroot -S$SOCKET_57 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    if [ "`$BASEDIR_80/bin/mysql -uroot -S$SOCKET_80 -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
  fi
  # If count reached 4 (there are 4 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
  if [ ${CLUSTER_UP} -eq 4 ]; then
    echo "2 Node PXC Cluster started ok. Clients:"
    echo "Node #1: `echo $BASEDIR_57/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_57"
    echo "Node #2: `echo $BASEDIR_80/bin/mysql | sed 's|/mysqld|/mysql|'` -uroot -S$SOCKET_80"
    break
  fi
done
