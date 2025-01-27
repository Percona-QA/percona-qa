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
  rm -rf $BASEDIR/pxc-node
fi

echo "Creating work directory"
WORKDIR=$BASEDIR/pxc-node
mkdir -p $WORKDIR $WORKDIR/cert $WORKDIR/kmip_certs

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
wsrep_debug=1
wsrep_cluster_address='gcomm://127.0.0.1:5030,127.0.0.1:6030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:4020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:4030;gcache.encryption=ON\"
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
wsrep_debug=1
wsrep_cluster_address='gcomm://127.0.0.1:4030,127.0.0.1:6030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:5020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:5030;gcache.encryption=ON\"
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
wsrep_cluster_address='gcomm://127.0.0.1:4030,127.0.0.1:5030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:6020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_debug=1
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:6030;gcache.encryption=ON;\"
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
  node=$1

  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET} ping > /dev/null 2>&1; then
      echo "Node$1 started successfully"
      break
    fi
    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
	    echo "Could not start the server. Error logs: $WORKDIR/node$1.err"
	    exit 1
    fi
  done
}

# Start KMIP server
start_kmip_server(){
  # Check if KMIP docker container is already running
  container_id=$(sudo docker ps -a | grep mohitpercona/kmip | awk '{print $1}')
  if [ -n "$container_id" ]; then
      sudo docker stop "$container_id" > /dev/null 2>&1
      sudo docker rm "$container_id" > /dev/null 2>&1
  fi
  # Start KMIP server with docker container
  sudo docker run -d --security-opt seccomp=unconfined --cap-add=NET_ADMIN --rm -p 5696:5696 --name kmip mohitpercona/kmip:latest
  sudo docker cp kmip:/opt/certs/root_certificate.pem ${WORKDIR}/kmip_certs
  sudo docker cp kmip:/opt/certs/client_key_jane_doe.pem ${WORKDIR}/kmip_certs
  sudo docker cp kmip:/opt/certs/client_certificate_jane_doe.pem ${WORKDIR}/kmip_certs

   # Generate component_keyring_kmip.cnf
   cat > ${WORKDIR}/kmip_certs/component_keyring_kmip.cnf <<EOF
{
   "server_addr": "127.0.0.1",
   "server_port": "5696",
   "client_ca": "${WORKDIR}/kmip_certs/client_certificate_jane_doe.pem",
   "client_key": "${WORKDIR}/kmip_certs/client_key_jane_doe.pem",
   "server_ca": "${WORKDIR}/kmip_certs/root_certificate.pem"
}
EOF
}

echo "Starting KMIP server"
start_kmip_server

echo "Creating data directories"
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn1 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node1.err 
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn2 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node2.err
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/pxc-node/dn3 --basedir=$BASEDIR --initialize-insecure --log-error=$BASEDIR/pxc-node/node3.err
echo "Data directory created"

echo "Create Global manifest file for node1/node2/node3"
cat > "$BASEDIR/bin/mysqld.my" <<EOF
{
 "read_local_manifest": true
}
EOF

echo "Create Local manifest file for node1"
cat > $WORKDIR/dn1/mysqld.my <<EOF
{
 "components": "file://component_keyring_kmip"
}
EOF

echo "Create Local manifest file for node2"
cp $WORKDIR/dn1/mysqld.my $WORKDIR/dn2/mysqld.my

echo "Create Local manifest file for node3"
cp $WORKDIR/dn1/mysqld.my $WORKDIR/dn3/mysqld.my

echo "Create Global config for node1/node2/node3"
cat > "$BASEDIR/lib/plugin/component_keyring_kmip.cnf" << EOF
{
 "read_local_config": true
}
EOF

echo "Create Local config for node1"
cp $WORKDIR/kmip_certs/component_keyring_kmip.cnf $WORKDIR/dn1
echo "Create Local config for node2"
cp $WORKDIR/kmip_certs/component_keyring_kmip.cnf $WORKDIR/dn2
echo "Create Local config for node3"
cp $WORKDIR/kmip_certs/component_keyring_kmip.cnf $WORKDIR/dn3


cp ${WORKDIR}/dn1/*.pem ${WORKDIR}/cert/

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
for X in $(seq 0 3); do
  sleep 10
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
