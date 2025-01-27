#!/bin/bash

#############################################################################################
# Created by: Mohit Joshi                                                                   #
# Creation date: 23-Jan-2025                                                                #
#                                                                                           #
# Script name: test_pxc_with_keyring_components.sh                                          #
#                                                                                           #
# This script is written to test Percona XtraDB cluster with data at rest encryption        #
# using different keyring components. In this script, we will be starting a 3 node PXC      #
# cluster using - component_keyring_file, component_keyring_vault, component_keyring_kms    #
# and component_keyring_vault                                                               #
#                                                                                           #
# Percona XtraDB cluster will be tested with both tarballs and manual builds                #
#############################################################################################

echo "Running tests against PXC tarballs by default. Alternatively set manual_build=1"
PXC_TARBALL=1
MANUAL_BUILD=0

BASEDIR=/home/mohit.joshi/pxc1
WORKDIR=$BASEDIR/pxc-node
SOCKET1=$WORKDIR/dn1/mysqld.sock
SOCKET2=$WORKDIR/dn2/mysqld.sock
SOCKET3=$WORKDIR/dn3/mysqld.sock
ERR_FILE1=$WORKDIR/node1.err
ERR_FILE2=$WORKDIR/node2.err
ERR_FILE3=$WORKDIR/node3.err
PXC_START_TIMEOUT=60

# Functions declaration
start_pxc_server() {
    # This function accepts single argument component name
    component_name=$1
    echo "=> Killing any previously running PXC server"
    pkill -9 mysqld > /dev/null 2>&1
    echo "..Killed"

    if [ -d $WORKDIR ]; then
        echo "=> Removing Old WorkDir"
        rm -rf $WORKDIR
        echo "..Removed"
    fi

    echo "=> Creating Workdir"
    mkdir -p $WORKDIR $WORKDIR/cert
    echo "..Workdir has been set: $WORKDIR"

    echo "=> Creating n1.cnf, n2.cnf and n3.cnf"
    create_pxc_config_file
    echo ".. Conf files created"

    #start_kmip_server

    echo "=> Creating data directories"
    $BASEDIR/bin/mysqld --no-defaults --datadir=$WORKDIR/dn1 --basedir=$BASEDIR --initialize-insecure --log-error=$WORKDIR/node1.err
    $BASEDIR/bin/mysqld --no-defaults --datadir=$WORKDIR/dn2 --basedir=$BASEDIR --initialize-insecure --log-error=$WORKDIR/node2.err
    $BASEDIR/bin/mysqld --no-defaults --datadir=$WORKDIR/dn3 --basedir=$BASEDIR --initialize-insecure --log-error=$WORKDIR/node3.err
    echo "..Data directory created"

    cp $WORKDIR/dn1/*.pem ${WORKDIR}/cert/

    if [ $component_name == "component_keyring_vault" ]; then
        start_vault_server
        setup_manifest_and_config_file $component_name
    elif [ $component_name == "component_keyring_file" ]; then
        setup_manifest_and_config_file $component_name
    elif [ $component_name == "component_keyring_kmip" ]; then
        start_kmip_server
        setup_manifest_and_config_file $component_name
    fi

    echo "=> Starting PXC nodes with $component_name"
    fetch_err_socket 1
    $BASEDIR/bin/mysqld --defaults-file=$WORKDIR/n1.cnf --wsrep_new_cluster > ${ERR_FILE} 2>&1 &
    pxc_startup_status 1

    fetch_err_socket 2
    $BASEDIR/bin/mysqld --defaults-file=$WORKDIR/n2.cnf > ${ERR_FILE} 2>&1 &
    pxc_startup_status 2

    fetch_err_socket 3
    $BASEDIR/bin/mysqld --defaults-file=$WORKDIR/n3.cnf > ${ERR_FILE} 2>&1 &
    pxc_startup_status 3

    echo "Checking 3 node PXC Cluster startup..."
    sleep 5
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

}

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

pxc_startup_status() {
    NR=$1
    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
        sleep 1
        if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET} ping > /dev/null 2>&1; then
            echo ".. PXC Node$NR started successfully"
            break
        fi
        if [ $X -eq ${PXC_START_TIMEOUT} ]; then
            echo "Node$NR failed to start. Check error logs at: $WORKDIR/node$NR.err"
            exit 1
        fi
    done
}

create_pxc_config_file() {
    echo "
[mysqld]

port = 4000
server-id=1
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR/
datadir=$WORKDIR/dn1
plugin_dir=$BASEDIR/lib/plugin/
log-error=$WORKDIR/node1.err
general_log=1
general_log_file=$WORKDIR/dn1/general.log
slow_query_log=1
slow_query_log_file=$WORKDIR/dn1/slow.log
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

echo "
[mysqld]

port = 5000
server-id=2
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR/
datadir=$WORKDIR/dn2
plugin_dir=$BASEDIR/lib/plugin
log-error=$WORKDIR/node2.err
general_log=1
general_log_file=$WORKDIR/dn2/general.log
slow_query_log=1
slow_query_log_file=$WORKDIR/dn2/slow.log
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

echo "
[mysqld]

port = 6000
server-id=3
log-error-verbosity=3
core-file

# file paths
basedir=$BASEDIR/
datadir=$WORKDIR/dn3
plugin_dir=$BASEDIR/lib/plugin
log-error=$WORKDIR/node3.err
general_log=1
general_log_file=$WORKDIR/dn3/general.log
slow_query_log=1
slow_query_log_file=$WORKDIR/dn3/slow.log
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
wsrep_debug=1
wsrep_cluster_address='gcomm://127.0.0.1:4030,127.0.0.1:5030'
wsrep_provider=$BASEDIR/lib/libgalera_smm.so
wsrep_sst_receive_address=127.0.0.1:6020
wsrep_node_incoming_address=127.0.0.1
wsrep_slave_threads=2
wsrep_cluster_name=my_pxc
wsrep_provider_options = \"gmcast.listen_addr=tcp://127.0.0.1:6030;gcache.encryption=ON\"
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
}

start_vault_server() {
    # Kill any previously running vault server
    killall vault > /dev/null 2>&1

    echo "=> Starting vault server"
    if [ ! -d $WORKDIR/vault ]; then
        mkdir $WORKDIR/vault
    fi
    rm -rf $WORKDIR/vault/*
    cp $HOME/percona-qa/vault_test_setup.sh $WORKDIR
    cp $HOME/percona-qa/get_download_link.sh $WORKDIR

    #VID=$(ps -eaf | grep 'vault server' | grep -v 'grep' | awk '{print $2}'); kill -9 $VID
    $WORKDIR/vault_test_setup.sh --workdir=$WORKDIR/vault --setup-pxc-mount-points --use-ssl > /dev/null 2>&1
    vault_url=$(grep 'vault_url' "${WORKDIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    secret_mount_point=$(grep 'secret_mount_point' "${WORKDIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    token=$(grep 'token' "${WORKDIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    vault_ca=$(grep 'vault_ca' "${WORKDIR}/vault/keyring_vault_ps.cnf" | awk -F '=' '{print $2}' | tr -d '[:space:]')
    echo ".. Vault server started"
}

setup_manifest_and_config_file() {
    component_name=$1
    echo "Creating Global manifest file for $component_name"
    cat > $BASEDIR/bin/mysqld.my << EOF
{
"read_local_manifest": true
}
EOF
    echo "Creating Global config file for $component_name"
    cat > $BASEDIR/lib/plugin/$component_name.cnf << EOF
{
"read_local_config": true
}
EOF
    for i in $(seq 1 3); do
        echo "Creating Local manifest file for $component_name, node$i"
        cat > $WORKDIR/dn$i/mysqld.my << EOF
{
"components": "file://$component_name"
}
EOF
    done

    if [ $component_name == "component_keyring_vault" ]; then
        for i in $(seq 1 3); do
            echo "Creating Local config file for $component_name, node$i"
            cat > $WORKDIR/dn$i/$component_name.cnf << EOF
{
"vault_url" : "$vault_url",
"secret_mount_point" : "$secret_mount_point",
"token" : "$token",
"vault_ca" : "$vault_ca"
}
EOF
        done
    elif [ $component_name == "component_keyring_file" ]; then
        for i in $(seq 1 3); do
            echo "Creating Local config file for $component_name, node$i"
            cat > $WORKDIR/dn$i/$component_name.cnf << EOF
{
"path": "$WORKDIR/dn$i/$component_name",
"read_only": false
}
EOF
        done
    elif [ $component_name == "component_keyring_kmip" ]; then
        for i in $(seq 1 3); do
            echo "Creating Local config for $component_name, node$i"
            cp $WORKDIR/kmip_certs/component_keyring_kmip.cnf $WORKDIR/dn$i
        done
    fi
}

# Start KMIP server
start_kmip_server(){
    # Check if KMIP docker container is already running
    container_id=$(sudo docker ps -a | grep mohitpercona/kmip | awk '{print $1}')
    if [ -n "$container_id" ]; then
        sudo docker stop "$container_id" > /dev/null 2>&1
        sudo docker rm "$container_id" > /dev/null 2>&1
    fi
    if [ -d $WORKDIR/kmip_certs ]; then
        rm -rf $WORKDIR/kmip_certs
    fi
    mkdir $WORKDIR/kmip_certs

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

# Actual test begins here ..
#start_pxc_server component_keyring_file
#start_pxc_server component_keyring_vault
start_pxc_server component_keyring_kmip
