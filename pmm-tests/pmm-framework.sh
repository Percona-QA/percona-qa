#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Additions by Roel Van de Paar, Percona LLC

# PMM Framework
# This script enables one to quickly setup a Percona Monitoring and Management environment. One can setup a PMM server and qucikyl add multiple clients
# The intention of this script is to be robust from a quality assurance POV; it should handle many different server configurations accurately

# Internal variables
WORKDIR=${PWD}
SCRIPT_PWD=$(cd `dirname $0` && pwd)
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SERVER_START_TIMEOUT=100
SUSER="root"
SPASS=""
OUSER="admin"
OPASS="passw0rd"
ADDR="127.0.0.1"

# User configurable variables
IS_BATS_RUN=0

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
    echo " --setup                   This will setup and configure a PMM server"
    echo " --addclient=ps,2          Add Percona (ps), MySQL (ms), MariaDB (md), and/or mongodb (mo) pmm-clients to the currently live PMM server (as setup by --setup)"
    echo "                           You can add multiple client instances simultaneously. eg : --addclient=ps,2  --addclient=ms,2 --addclient=md,2 --addclient=mo,2"
    echo " --mongo-with-rocksdb       This will start mongodb with rocksdb engine" 
    echo " --add-docker-client       Add docker pmm-clients with percona server to the currently live PMM server" 
    echo " --list                    List all client information as obtained from pmm-admin"
    echo " --wipe-clients            This will stop all client instances and remove all clients from pmm-admin"
    echo " --wipe-docker-clients     This will stop all docker client instances and remove all clients from docker container"
    echo " --wipe-server             This will stop pmm-server container and remove all pmm containers"
    echo " --wipe                    This will wipe all pmm configuration"
    echo " --dev                     When this option is specified, PMM framework will use the latest PMM development version. Otherwise, the latest 1.0.x version is used"
    echo " --pmm-server-username     User name to access the PMM Server web interface"
    echo " --pmm-server-password     Password to access the PMM Server web interface"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=u: --longoptions=addclient:,pmm-server-username:,pmm-server-password::,setup,mongo-with-rocksdb,add-docker-client,list,wipe-clients,wipe-docker-clients,wipe-server,wipe,dev,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- $go_out
fi

if [[ $go_out == " --" ]];then
  usage
  exit 1
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    --addclient )
    ADDCLIENT+=("$2")
    shift 2
    ;;
    --mongo-with-rocksdb )
    shift
    mongo_with_rocksdb=1
    ;;   
    --add-docker-client )
    shift
    add_docker_client=1
    ;;
    --setup )
    shift
    setup=1
    ;;
    --list )
    shift
    list=1
    ;;
    --wipe-clients )
    shift
    wipe_clients=1
    ;;
    --wipe-docker-clients )
    shift
    wipe_docker_clients=1
    ;;
    --wipe-server )
    shift
    wipe_server=1
    ;;
    --wipe )
    shift
    wipe=1
    ;;
    --dev )
    shift
    dev=1
    ;;
    --pmm-server-username )
    pmm_server_username="$2"
    shift 2
    ;;
    --pmm-server-password )
    case "$2" in
      "")
      read -r -s -p  "Enter PMM Server web interface password:" INPUT_PASS
      if [ -z "$INPUT_PASS" ]; then
        pmm_server_password=""
	printf "\nConfiguring without PMM Server web interface password...\n";
      else
        pmm_server_password="$INPUT_PASS"
      fi
      printf "\n"
      ;;
      *)
      pmm_server_password="$2"
      ;;
    esac
    shift 2
    ;;
    --help )
    usage
    exit 0
    ;;
  esac
done

if [[ -z "$pmm_server_username" ]];then
  if [[ ! -z "$pmm_server_password" ]];then
    echo "ERROR! PMM Server web interface username is empty. Terminating"
    exit 1
  fi
fi

sanity_check(){
  if ! sudo docker ps | grep 'pmm-server' > /dev/null ; then
    echo "ERROR! pmm-server docker container is not runnning. Terminating"
    exit 1
  fi
}

setup(){
  if [ $IS_BATS_RUN -eq 0 ];then
  read -p "Would you like to enable SSL encryption to protect PMM from unauthorized access[y/n] ? " check_param
    case $check_param in
      y|Y)
        echo -e "\nGenerating SSL certificate files to protect PMM from unauthorized access"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout server.key -out server.crt -subj '/CN=www.percona.com/O=Database Performance./C=US'
         IS_SSL="Yes"
      ;;
      n|N)
        echo ""
        IS_SSL="No"
      ;;
      *)
        echo "Please type [y/n]! Terminating."
        exit 1
      ;;
    esac
  else
    IS_SSL="No"
  fi

  if [[ ! -e $(which lynx 2> /dev/null) ]] ;then
    echo "ERROR! The program 'lynx' is currently not installed. Please install lynx. Terminating"
    exit 1
  fi

  #PMM configuration setup
  if [ ! -z $dev ]; then
    PMM_VERSION=$(lynx --dump https://hub.docker.com/r/percona/pmm-server/tags/ | grep 1.0 | sed 's|   ||' | head -n1)
  else
    PMM_VERSION=$(lynx --dump https://hub.docker.com/r/percona/pmm-server/tags/ | grep 1.0 | sed 's|   ||' | grep -v dev | head -n1)
  fi

  #PMM sanity check
  if ! pgrep docker > /dev/null ; then
    echo "ERROR! docker service is not running. Terminating"
    exit 1
  fi
  if sudo docker ps | grep 'pmm-server' > /dev/null ; then
    echo "ERROR! pmm-server docker container is already runnning. Terminating"
    exit 1
  elif  sudo docker ps -a | grep 'pmm-server' > /dev/null ; then
    CONTAINER_NAME=$(sudo docker ps -a | grep 'pmm-server' | grep $PMM_VERSION | grep -v pmm-data | awk '{ print $1}')
    echo "ERROR! The name 'pmm-server' is already in use by container $CONTAINER_NAME"
    exit 1
  fi

  echo "Initiating PMM configuration"
  sudo docker create -v /opt/prometheus/data -v /opt/consul-data -v /var/lib/mysql -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" --name pmm-data percona/pmm-server:$PMM_VERSION /bin/true 2>/dev/null
  if [ "$IS_SSL" == "Yes" ];then
    sudo docker run -d -p 443:443 -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" -e ORCHESTRATOR_USER=$OUSER -e ORCHESTRATOR_PASSWORD=$OPASS --volumes-from pmm-data --name pmm-server -v $WORKDIR:/etc/nginx/ssl  --restart always percona/pmm-server:$PMM_VERSION 2>/dev/null
  else
    sudo docker run -d -p 80:80 -e SERVER_USER="$pmm_server_username" -e SERVER_PASSWORD="$pmm_server_password" -e ORCHESTRATOR_USER=$OUSER -e ORCHESTRATOR_PASSWORD=$OPASS --volumes-from pmm-data --name pmm-server --restart always percona/pmm-server:$PMM_VERSION 2>/dev/null
  fi

  echo "Initiating PMM client configuration"
  PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
  if [ -z $PMM_CLIENT_BASEDIR ]; then
    PMM_CLIENT_TAR=$(ls -1td pmm-client-* | grep ".tar" | head -n1)
    if [ ! -z $PMM_CLIENT_TAR ];then
      tar -xzf $PMM_CLIENT_TAR
      PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
      pushd $PMM_CLIENT_BASEDIR > /dev/null
      sudo ./install
      popd > /dev/null
    else
      if [ ! -z $dev ]; then
        PMM_CLIENT_TAR=$(lynx --dump https://www.percona.com/downloads/TESTING/pmm/ | grep -o pmm-client.*.tar.gz   | head -n1)
        wget https://www.percona.com/downloads/TESTING/pmm/$PMM_CLIENT_TAR
        tar -xzf $PMM_CLIENT_TAR
        PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
        pushd $PMM_CLIENT_BASEDIR > /dev/null
        sudo ./install
        popd > /dev/null
      else
        PMM_CLIENT_TAR=$(lynx --dump  https://www.percona.com/downloads/pmm-client/pmm-client-1.0.6/binary/tarball | grep -o pmm-client.*.tar.gz | head -n1)
        wget https://www.percona.com/downloads/pmm-client/pmm-client-1.0.6/binary/tarball/$PMM_CLIENT_TAR
        tar -xzf $PMM_CLIENT_TAR
        PMM_CLIENT_BASEDIR=$(ls -1td pmm-client-* | grep -v ".tar" | head -n1)
        pushd $PMM_CLIENT_BASEDIR > /dev/null
        sudo ./install
        popd > /dev/null
      fi
    fi
  else
    pushd $PMM_CLIENT_BASEDIR > /dev/null
    sudo ./install
    popd > /dev/null
  fi

  if [[ ! -e $(which pmm-admin 2> /dev/null) ]] ;then
    echo "ERROR! The pmm-admin client binary was not found, please install the pmm-admin client package"
    exit 1
  else
    sleep 10
    IP_ADDRESS=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
    if [ "$IS_SSL" == "Yes" ];then
      sudo pmm-admin config --server $IP_ADDRESS --server-user="$pmm_server_username" --server-password="$pmm_server_password" --server-insecure-ssl
    else
      sudo pmm-admin config --server $IP_ADDRESS --server-user="$pmm_server_username" --server-password="$pmm_server_password"
    fi
  fi
  echo -e "******************************************************************"
  echo -e "Please execute below command to access docker container"
  echo -e "docker exec -it pmm-server bash\n"
  if [ "$IS_SSL" == "Yes" ];then
    (
    printf "%s\t%s\n" "PMM landing page" "https://$IP_ADDRESS:443"
    if [ ! -z $pmm_server_username ];then
      printf "%s\t%s\n" "PMM landing page username" "$pmm_server_username"
    fi
    if [ ! -z $pmm_server_password ];then
      printf "%s\t%s\n" "PMM landing page password" "$pmm_server_password"
    fi
    printf "%s\t%s\n" "Query Analytics (QAN web app)" "https://$IP_ADDRESS:443/qan"
    printf "%s\t%s\n" "Metrics Monitor (Grafana)" "https://$IP_ADDRESS:443/graph"
    printf "%s\t%s\n" "Metrics Monitor username" "admin"
    printf "%s\t%s\n" "Metrics Monitor password" "admin"
    printf "%s\t%s\n" "Orchestrator" "https://$IP_ADDRESS:443/orchestrator"
    ) | column -t -s $'\t'
  else
    (
    printf "%s\t%s\n" "PMM landing page" "http://$IP_ADDRESS"
    if [ ! -z $pmm_server_username ];then
      printf "%s\t%s\n" "PMM landing page username" "$pmm_server_username"
    fi
    if [ ! -z $pmm_server_password ];then
      printf "%s\t%s\n" "PMM landing page password" "$pmm_server_password"
    fi
    printf "%s\t%s\n" "Query Analytics (QAN web app)" "http://$IP_ADDRESS/qan"
    printf "%s\t%s\n" "Metrics Monitor (Grafana)" "http://$IP_ADDRESS/graph"
    printf "%s\t%s\n" "Metrics Monitor username" "admin"
    printf "%s\t%s\n" "Metrics Monitor password" "admin"
    printf "%s\t%s\n" "Orchestrator" "http://$IP_ADDRESS/orchestrator"
    ) | column -t -s $'\t'
  fi
  echo -e "******************************************************************"
}

#Percona Server configuration.
add_clients(){
  mkdir -p $WORKDIR/logs
  for i in ${ADDCLIENT[@]};do
    CLIENT_NAME=$(echo $i | grep -o  '[[:alpha:]]*')
    if [[ "${CLIENT_NAME}" == "ps" ]]; then
      PORT_CHECK=101
      NODE_NAME="PS_NODE"
      BASEDIR=$(ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1)
      if [ -z $BASEDIR ]; then
        BASE_TAR=$(ls -1td ?ercona-?erver-5.* | grep ".tar" | head -n1)
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=$(ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1)
          BASEDIR="$WORKDIR/$BASEDIR"
          rm -rf $BASEDIR/node*
        else
          echo "ERROR! Percona Server binary tar ball does not exist. Terminating."
          exit 1
        fi
      else
        BASEDIR="$WORKDIR/$BASEDIR"
      fi
    elif [[ "${CLIENT_NAME}" == "ms" ]]; then
      PORT_CHECK=201
      NODE_NAME="MS_NODE"
      BASEDIR=$(ls -1td mysql-5.* | grep -v ".tar" | head -n1)
      if [ -z $BASEDIR ]; then
        BASE_TAR=$(ls -1td mysql-5.* | grep ".tar" | head -n1)
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=$(ls -1td mysql-5.* | grep -v ".tar" | head -n1)
          BASEDIR="$WORKDIR/$BASEDIR"
          rm -rf $BASEDIR/node*
        else
          echo "ERROR! MySQL Server binary tar ball does not exist. Terminating."
          exit 1
        fi
      else
        BASEDIR="$WORKDIR/$BASEDIR"
      fi
    elif [[ "${CLIENT_NAME}" == "md" ]]; then
      PORT_CHECK=301
      NODE_NAME="MD_NODE"
      BASEDIR=$(ls -1td mariadb-* | grep -v ".tar" | head -n1)
      if [ -z $BASEDIR ]; then
        BASE_TAR=$(ls -1td mariadb-* | grep ".tar" | head -n1)
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=$(ls -1td mariadb-* | grep -v ".tar" | head -n1)
          BASEDIR="$WORKDIR/$BASEDIR"
          rm -rf $BASEDIR/node*
        else
          echo "ERROR! MariaDB binary tar ball does not exist. Terminating."
          exit 1
        fi
      else
        BASEDIR="$WORKDIR/$BASEDIR"
      fi
    elif [[ "${CLIENT_NAME}" == "pxc" ]]; then
      echo "[mysqld]" > my_pxc.cnf
      echo "innodb_autoinc_lock_mode=2" >> my_pxc.cnf
      echo "innodb_locks_unsafe_for_binlog=1" >> my_pxc.cnf
      echo "wsrep-provider=${BASEDIR}/lib/libgalera_smm.so" >> my_pxc.cnf
      echo "wsrep_node_incoming_address=$ADDR" >> my_pxc.cnf
      echo "wsrep_sst_method=rsync" >> my_pxc.cnf
      echo "wsrep_sst_auth=$SUSER:$SPASS" >> my_pxc.cnf
      echo "wsrep_node_address=$ADDR" >> my_pxc.cnf
      echo "server-id=1" >> my_pxc.cnf
      echo "wsrep_slave_threads=2" >> my_pxc.cnf
      PORT_CHECK=401
      NODE_NAME="PXC_NODE"
      BASEDIR=$(ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1)
      if [ -z $BASEDIR ]; then
        BASE_TAR=$(ls -1td Percona-XtraDB-Cluster-5.* | grep ".tar" | head -n1)
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=$(ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1)
          BASEDIR="$WORKDIR/$BASEDIR"
          rm -rf $BASEDIR/node*
        else
          echo "ERROR! Percona XtraDB Cluster binary tar ball does not exist. Terminating."
          exit 1
        fi
      else
        BASEDIR="$WORKDIR/$BASEDIR"
      fi
    elif [[ "${CLIENT_NAME}" == "mo" ]]; then
      if [[ ! -e $(which mlaunch 2> /dev/null) ]] ;then
        echo "WARNING! The mlaunch mongodb spin up local test environments tool is not installed. Configuring MondoDB server manually"
      else
        MTOOLS_MLAUNCH=$(which mlaunch)
      fi
      BASEDIR=$(ls -1td percona-server-mongodb-* | grep -v ".tar" | head -n1)
      if [ -z $BASEDIR ]; then
        BASE_TAR=$(ls -1td percona-server-mongodb-* | grep ".tar" | head -n1)
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=$(ls -1td percona-server-mongodb-* | grep -v ".tar" | head -n1)
          BASEDIR="$WORKDIR/$BASEDIR"
          sudo rm -rf $BASEDIR/data
        else
          echo "ERROR! Percona Server Mongodb binary tar ball does not exist. Terminating."
          exit 1
        fi
      else
        BASEDIR="$WORKDIR/$BASEDIR"
      fi
    fi
    if [[ "${CLIENT_NAME}" != "md"  && "${CLIENT_NAME}" != "mo" ]]; then
      if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
        MID="${BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BASEDIR}"
      else
        MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
      fi
    else
      if [[ "${CLIENT_NAME}" != "mo" ]]; then
        MID="${BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${BASEDIR}"
      fi
    fi

    ADDCLIENTS_COUNT=$(echo "${i}" | sed 's|[^0-9]||g')
    if  [[ "${CLIENT_NAME}" == "mo" ]]; then
      PSMDB_PORT=27017
      if [ ! -z $mongo_with_rocksdb ]; then
        mkdir $BASEDIR/replset
        for j in `seq 1  ${ADDCLIENTS_COUNT}`;do
          PORT=$(( $PSMDB_PORT + $j - 1 ))
          sudo mkdir -p ${BASEDIR}/data/db$j
          sudo $BASEDIR/bin/mongod --storageEngine rocksdb --replSet replset --dbpath=$BASEDIR/data/db$j --logpath=$BASEDIR/data/db$j/mongod.log --port=$PORT --logappend --fork &
          sleep 5
        done
        sudo pmm-admin add  mongodb:metrics
      else
        if [ ! -z $MTOOLS_MLAUNCH ];then
          sudo $MTOOLS_MLAUNCH --replicaset --nodes $ADDCLIENTS_COUNT --binarypath=$BASEDIR/bin --dir=${BASEDIR}/data
        else
          mkdir $BASEDIR/replset
          for j in `seq 1  ${ADDCLIENTS_COUNT}`;do
            PORT=$(( $PSMDB_PORT + $j - 1 ))
            sudo mkdir -p ${BASEDIR}/data/db$j
            sudo $BASEDIR/bin/mongod --replSet replset --dbpath=$BASEDIR/data/db$j --logpath=$BASEDIR/data/db$j/mongod.log --port=$PORT --logappend --fork &
            sleep 5
          done
        fi
        sudo pmm-admin add  mongodb:metrics
      fi
    else
      for j in `seq 1  ${ADDCLIENTS_COUNT}`;do
        RBASE1="$(( RBASE + ( $PORT_CHECK * $j ) ))"
        LADDR1="$ADDR:$(( RBASE1 + 8 ))"
        node="${BASEDIR}/node$j"
        if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
          echo "WARNING! Another mysqld process using /tmp/${NODE_NAME}_${j}.sock"
          if ! sudo pmm-admin list | grep "/tmp/${NODE_NAME}_${j}.sock" > /dev/null ; then
            sudo pmm-admin add mysql ${NODE_NAME}-${j} --socket=/tmp/${NODE_NAME}_${j}.sock --user=root --query-source=perfschema
          fi
          continue
        fi
        if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
          mkdir -p $node
          ${MID} --datadir=$node  > ${BASEDIR}/startup_node$j.err 2>&1
        else
          if [ ! -d $node ]; then
            ${MID} --datadir=$node  > ${BASEDIR}/startup_node$j.err 2>&1
          fi
        fi
        if  [[ "${CLIENT_NAME}" == "pxc" ]]; then
          WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
          if [ $j -eq 1 ]; then
            WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
          else
            WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
          fi
          MYEXTRA="--no-defaults $WSREP_CLUSTER_ADD --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 "
        else
          MYEXTRA="--no-defaults"
        fi
        ${BASEDIR}/bin/mysqld $MYEXTRA --basedir=${BASEDIR} --datadir=$node --log-error=$node/error.err \
          --socket=/tmp/${NODE_NAME}_${j}.sock --port=$RBASE1  > $node/error.err 2>&1 &
        for X in $(seq 0 ${SERVER_START_TIMEOUT}); do
          sleep 1
          if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
            check_user=`${BASEDIR}/bin/mysql  -uroot -S/tmp/${NODE_NAME}_${j}.sock -e "SELECT user,host FROM mysql.user where user='$OUSER' and host='%';"`
            if [[ -z "$check_user" ]]; then
              ${BASEDIR}/bin/mysql  -uroot -S/tmp/${NODE_NAME}_${j}.sock -e "CREATE USER '$OUSER'@'%' IDENTIFIED BY '$OPASS';GRANT SUPER, PROCESS, REPLICATION SLAVE, RELOAD ON *.* TO '$OUSER'@'%'"
              (
              printf "%s\t%s\n" "Orchestrator username :" "admin"
              printf "%s\t%s\n" "Orchestrator password :" "passw0rd"
              ) | column -t -s $'\t'
            else
              echo "User '$OUSER' is already present in MySQL server. Please create Orchestrator user manually."
            fi
            break
          fi
          if ! ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/${NODE_NAME}_${j}.sock ping > /dev/null 2>&1; then
            echo "ERROR! ${NODE_NAME} startup failed. Please check error log $node/error.err"
            exit 1
          fi
        done
        sudo pmm-admin add mysql ${NODE_NAME}-${j} --socket=/tmp/${NODE_NAME}_${j}.sock --user=root --query-source=perfschema
      done
    fi
  done
}

pmm_docker_client_startup(){
  centos_docker_client(){
    rm -rf Dockerfile docker-compose.yml
    echo "FROM centos:centos6" >> Dockerfile
    echo "RUN yum install -y http://www.percona.com/downloads/percona-release/redhat/0.1-4/percona-release-0.1-4.noarch.rpm" >> Dockerfile
    echo "RUN yum install -y yum install Percona-Server-server-57 pmm-client" >> Dockerfile
    echo "RUN echo \"UNINSTALL PLUGIN validate_password;\" > init.sql " >> Dockerfile
    echo "RUN echo \"ALTER USER  root@localhost IDENTIFIED BY '';\" >> init.sql " >> Dockerfile
    echo "RUN echo \"CREATE USER root@'%';\" >> init.sql " >> Dockerfile
    echo "RUN echo \"GRANT ALL ON *.* TO root@'%';\" >> init.sql" >> Dockerfile
    echo "RUN service mysql start" >> Dockerfile
    echo "EXPOSE 3306 42000 42002 42003 42004" >> Dockerfile
    echo "centos_ps:" >> docker-compose.yml
    echo "   build: ." >> docker-compose.yml
    echo "   hostname: centos_ps1" >> docker-compose.yml
    echo "   command: sh -c \"mysqld --init-file=/init.sql --user=root\"" >> docker-compose.yml
    echo "   ports:" >> docker-compose.yml
    echo "      - \"3306\"" >> docker-compose.yml
    echo "      - \"42000\"" >> docker-compose.yml
    echo "      - \"42002\"" >> docker-compose.yml
    echo "      - \"42003\"" >> docker-compose.yml
    echo "      - \"42004\"" >> docker-compose.yml
    docker-compose up >/dev/null 2>&1 &
    BASE_DIR=$(basename "$PWD")
    BASE_DIR=${BASE_DIR//[^[:alnum:]]/}
    while ! docker ps | grep ${BASE_DIR}_centos_ps_1 > /dev/null; do  
      sleep 5 ; 
    done
    DOCKER_CONTAINER_NAME=$(docker ps | grep ${BASE_DIR}_centos_ps | awk '{print $NF}')
    IP_ADD=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
    if [ ! -z $DOCKER_CONTAINER_NAME ]; then
      echo -e "\nAdding pmm-client instance from CentOS docker container to the currently live PMM server" 
      IP_DOCKER_ADD=$(docker exec -it $DOCKER_CONTAINER_NAME ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin config --server $IP_ADD --bind-address $IP_DOCKER_ADD
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin add mysql
    fi
  }

  ubuntu_docker_client(){
    rm -rf Dockerfile docker-compose.yml
    echo "FROM ubuntu:16.04" >> Dockerfile
    echo "RUN apt-get update" >> Dockerfile
    echo "RUN apt-get install -y wget lsb-release net-tools vim iproute" >> Dockerfile
    echo "RUN wget http://repo.percona.com/apt/percona-release_0.1-4.\$(lsb_release -sc)_all.deb" >> Dockerfile
    echo "RUN dpkg -i percona-release_0.1-4.\$(lsb_release -sc)_all.deb" >> Dockerfile
    echo "RUN apt-get update" >> Dockerfile
    echo "RUN apt-get install -y percona-server-server-5.7 pmm-client" >> Dockerfile
    echo "RUN echo \"CREATE USER root@'%';\" > init.sql " >> Dockerfile
    echo "RUN echo \"GRANT ALL ON *.* TO root@'%';\" >> init.sql" >> Dockerfile
    echo "RUN service mysql start" >> Dockerfile
    echo "EXPOSE 3306 42000 42002 42003 42004" >> Dockerfile
    echo "ubuntu_ps:" >> docker-compose.yml
    echo "   build: ." >> docker-compose.yml
    echo "   hostname: ubuntu_ps1" >> docker-compose.yml
    echo "   command: sh -c \"mysqld --init-file=/init.sql\"" >> docker-compose.yml
    echo "   ports:" >> docker-compose.yml
    echo "      - 3306:3306" >> docker-compose.yml
    echo "      - 42000:42000" >> docker-compose.yml
    echo "      - 42002:42002" >> docker-compose.yml
    echo "      - 42003:42003" >> docker-compose.yml
    echo "      - 42004:42004" >> docker-compose.yml
    docker-compose up >/dev/null 2>&1 &
    BASE_DIR=$(basename "$PWD")
    BASE_DIR=${BASE_DIR//[^[:alnum:]]/}
    while ! docker ps | grep ${BASE_DIR}_ubuntu_ps_1 > /dev/null; do  
      sleep 5 ; 
    done
    DOCKER_CONTAINER_NAME=$(docker ps | grep ${BASE_DIR}_ubuntu_ps | awk '{print $NF}')
    IP_ADD=$(ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
    if [ ! -z $DOCKER_CONTAINER_NAME ]; then
      echo -e "\nAdding pmm-client instance from Ubuntu docker container to the currently live PMM server" 
      IP_DOCKER_ADD=$(docker exec -it $DOCKER_CONTAINER_NAME ip route get 8.8.8.8 | head -1 | cut -d' ' -f8)
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin config --server $IP_ADD --bind-address $IP_DOCKER_ADD
      docker exec -it $DOCKER_CONTAINER_NAME pmm-admin add mysql
    fi
  }

  centos_docker_client
  ubuntu_docker_client
}
clean_clients(){
  if [[ ! -e $(which mysqladmin 2> /dev/null) ]] ;then
    MYSQLADMIN_CLIENT=$(find . -name mysqladmin | head -n1)
  else
    MYSQLADMIN_CLIENT=$(which mysqladmin)
  fi
  if [[ -z "$MYSQLADMIN_CLIENT" ]];then
   echo "ERROR! 'mysqladmin' is currently not installed. Please install mysqladmin. Terminating."
   exit 1
  fi
  #Shutdown all mysql client instances
  for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
    echo -e "Shutting down mysql instance (--socket=${i})" 
    ${MYSQLADMIN_CLIENT} -uroot --socket=${i} shutdown
    sleep 2
  done
  #Kills mongodb processes
  echo -e "Killing mongodb processes" 
  sudo killall mongod 2> /dev/null
  sleep 5
  #Remove all client instances
  echo -e "Removing all local pmm client instances" 
  sudo pmm-admin remove --all 2&>/dev/null
}

clean_docker_clients(){
  #Remove docker pmm-clients
  BASE_DIR=$(basename "$PWD")
  BASE_DIR=${BASE_DIR//[^[:alnum:]]/}
  echo -e "Removing pmm-client instances from docker containers" 
  sudo docker exec -it ${BASE_DIR}_centos_ps_1  pmm-admin remove --all 2&> /dev/null
  sudo docker exec -it ${BASE_DIR}_ubuntu_ps_1  pmm-admin remove --all  2&> /dev/null
  echo -e "Removing pmm-client docker containers" 
  sudo docker stop ${BASE_DIR}_ubuntu_ps_1 ${BASE_DIR}_centos_ps_1  2&> /dev/null
  sudo docker rm ${BASE_DIR}_ubuntu_ps_1 ${BASE_DIR}_centos_ps_1  2&> /dev/null
}

clean_server(){
  #Stop/Remove pmm-server docker containers
  echo -e "Removing pmm-server docker containers" 
  sudo docker stop pmm-server  2&> /dev/null
  sudo docker rm pmm-server pmm-data  2&> /dev/null
}

if [ ! -z $wipe_clients ]; then
  clean_clients
fi

if [ ! -z $wipe_docker_clients ]; then
  clean_docker_clients
fi

if [ ! -z $wipe_server ]; then
  clean_server
fi

if [ ! -z $wipe ]; then
  clean_clients
  clean_docker_clients
  clean_server
fi

if [ ! -z $list ]; then
  sudo pmm-admin list
fi

if [ ! -z $setup ]; then
  setup
fi

if [ ${#ADDCLIENT[@]} -ne 0 ]; then
  sanity_check
  add_clients
fi

if [ ! -z $add_docker_client ]; then
  sanity_check
  pmm_docker_client_startup
fi

exit 0
