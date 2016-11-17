#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Additions by Roel Van de Paar, Percona LLC

# PMM Framework
# This script enables one to quickly setup a Percona Monitoring and Management environment. One can setup a PMM server and qucikyl add multiple clients
# The intention of this script is to be robust from a quality assurance POV; it should handle many different server configurations accurately

# Internal variables
WORKDIR=${PWD}
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SERVER_START_TIMEOUT=100
SUSER=root
SPASS=""
ADDR="127.0.0.1"

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
    echo " --setup                   This will setup and configure a PMM server"
    echo " --addclient=ps,2          Add Percona (ps), MySQL (ms), MariaDB (md), and/or mongodb (mo) pmm-clients to the currently live PMM server (as setup by --setup)"
    echo "                           You can add multiple client instances simultaneously. eg : --addclient=ps,2  --addclient=ms,2 --addclient=md,2 --addclient=mo,2"
    echo " --list                    List all the client information from pmm-admin"
    echo " --clean                   It will stop all client instances and remove from pmm-admin"
    echo " --dev                     It wil configure PMM beta version"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options= --longoptions=addclient:,setup,list,clean,dev,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- $go_out
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    --addclient )
    ADDCLIENT+=("$2")
    shift 2
    ;;
    --setup )
    shift
    setup=1
    ;;
    --list )
    shift
    list=1
    ;;
    --clean )
    shift
    clean=1
    ;;
    --dev )
    shift
    dev=1
    ;;
    --help )
    usage
    exit 0
    ;;
  esac
done

if [ ! -z $setup ]; then
  if [[ ! -e `which lynx 2> /dev/null` ]] ;then
    echo "ERROR! The program 'lynx' is currently not installed. Please install lynx. Terminating"  
    exit 1
  fi
  #PMM configuration setup
  mkdir -p $WORKDIR/pmm
  rm -rf $WORKDIR/pmm/index.html
  pushd $WORKDIR/pmm
  wget -q https://hub.docker.com/r/percona/pmm-server/tags/
  if [ ! -z $dev ]; then
    PMM_VERSION=`lynx --dump index.html | grep 1.0 | sed 's|   ||' | head -n1`
  else
    PMM_VERSION=`lynx --dump index.html | grep 1.0 | sed 's|   ||' | grep -v dev | head -n1`
  fi
  popd

  #PMM sanity check
  if ! ps -ef | grep docker | grep -q daemon; then
    echo "ERROR! docker service is not running. Terminating"
    exit 1
  fi
  if sudo docker ps | grep 'pmm-server' > /dev/null ; then
    echo "ERROR! pmm-server docker container is alreay runnning. Terminating"
    exit 1
  elif  sudo docker ps -a | grep 'pmm-server' > /dev/null ; then
    CONTAINER_NAME=$(sudo docker ps -a | grep 'pmm-server' | grep $PMM_VERSION | grep -v pmm-data | awk '{ print $1}')
    echo "ERROR! The name 'pmm-server' is already in use by container $CONTAINER_NAME"
    exit 1
  fi

  echo "Initiating PMM configuration"
  sudo docker create -v /opt/prometheus/data -v /opt/consul-data -v /var/lib/mysql --name pmm-data percona/pmm-server:$PMM_VERSION /bin/true 2>/dev/null 
  sudo docker run -d -p 80:80 --volumes-from pmm-data --name pmm-server --restart always percona/pmm-server:$PMM_VERSION 2>/dev/null

  mkdir -p $WORKDIR/pmm_client
  rm -rf $WORKDIR/pmm_client/index.html

  pushd $WORKDIR/pmm_client
  wget -q https://www.percona.com/downloads/TESTING/pmm/
  if [ ! -z $dev ]; then
    PMM_CLIENT_TAR=$(grep pmm-client $WORKDIR/pmm_client/index.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g'  | grep -E 'dev.*tar.gz' | head -n1 | awk '{ print $1}')
  else
    PMM_CLIENT_TAR=$(grep pmm-client $WORKDIR/pmm_client/index.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g'  | grep -E 'tar.gz' | grep -v dev | head -n1 | awk '{ print $1}')
  fi
  if ! ls -1 $PMM_CLIENT_TAR 2> /dev/null >/dev/null; then 
    wget -q https://www.percona.com/downloads/TESTING/pmm/$PMM_CLIENT_TAR
  fi
  tar -xzf $PMM_CLIENT_TAR
  PMM_CLIENT_BASEDIR=`ls -1td pmm-client-* | grep -v ".tar" | head -n1`
  cd $PMM_CLIENT_BASEDIR
  sudo ./install
  popd
  
  if [[ ! -e `which pmm-admin 2> /dev/null` ]] ;then
    echo "ERROR! The pmm-admin client binary was not found, please install the pmm-admin client package"  
    exit 1
  else
    sleep 10
    IP_ADDRESS=`ip route get 8.8.8.8 | head -1 | cut -d' ' -f8`
    sudo pmm-admin config --server $IP_ADDRESS
  fi
  echo -e "******************************************************************"
  echo -e "Please execute below command to access docker container"
  echo -e "docker exec -it pmm-server bash\n"
  (
  printf "%s\t%s\n" "PMM landing page" "http://$IP_ADDRESS"
  printf "%s\t%s\n" "Query Analytics (QAN web app)" "http://$IP_ADDRESS/qan"
  printf "%s\t%s\n" "Metrics Monitor (Grafana)" "http://$IP_ADDRESS/graph"
  printf "%s\t%s\n" " " "user name: admin"
  printf "%s\t%s\n" " " "password : admin"
  printf "%s\t%s\n" "Orchestrator" "http://$IP_ADDRESS/orchestrator"
  ) | column -t -s $'\t'
  echo -e "******************************************************************"
fi

#Percona Server configuration.
add_ps_client(){
  mkdir -p $WORKDIR/logs
  for i in ${ADDCLIENT[@]};do
    CLIENT_NAME=`echo $i | grep -o  '[[:alpha:]]*'`
    if [[ "${CLIENT_NAME}" == "ps" ]]; then
      PORT_CHECK=101
      NODE_NAME="PS_NODE"
      BASEDIR=`ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1`
      if [ -z $BASEDIR ]; then
        BASE_TAR=`ls -1td ?ercona-?erver-5.* | grep ".tar" | head -n1`
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=`ls -1td ?ercona-?erver-5.* | grep -v ".tar" | head -n1`
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
      BASEDIR=`ls -1td mysql-5.* | grep -v ".tar" | head -n1`
      if [ -z $BASEDIR ]; then
        BASE_TAR=`ls -1td mysql-5.* | grep ".tar" | head -n1`
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=`ls -1td mysql-5.* | grep -v ".tar" | head -n1`
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
      BASEDIR=`ls -1td mariadb-* | grep -v ".tar" | head -n1`
      if [ -z $BASEDIR ]; then
        BASE_TAR=`ls -1td mariadb-* | grep ".tar" | head -n1`
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=`ls -1td mariadb-* | grep -v ".tar" | head -n1`
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
      BASEDIR=`ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1`
      if [ -z $BASEDIR ]; then
        BASE_TAR=`ls -1td Percona-XtraDB-Cluster-5.* | grep ".tar" | head -n1`
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=`ls -1td Percona-XtraDB-Cluster-5.* | grep -v ".tar" | head -n1`
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
      if [[ ! -e `which mlaunch 2> /dev/null` ]] ;then
        echo "WARNING! The mlaunch mongodb spin up local test environments tool is not installed. Configuring MondoDB server manually"
      else
        MTOOLS_MLAUNCH=`which mlaunch`
      fi
      BASEDIR=`ls -1td percona-server-mongodb-* | grep -v ".tar" | head -n1`
      if [ -z $BASEDIR ]; then
        BASE_TAR=`ls -1td percona-server-mongodb-* | grep ".tar" | head -n1`
        if [ ! -z $BASE_TAR ];then
          tar -xzf $BASE_TAR
          BASEDIR=`ls -1td percona-server-mongodb-* | grep -v ".tar" | head -n1`
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
    else
      for j in `seq 1  ${ADDCLIENTS_COUNT}`;do
        RBASE1="$(( RBASE + ( $PORT_CHECK * $j ) ))"
        LADDR1="$ADDR:$(( RBASE1 + 8 ))"
        node="${BASEDIR}/node$j"
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
          --socket=$node/n${j}.sock --port=$RBASE1  > $node/error.err 2>&1 &
        for X in $(seq 0 ${SERVER_START_TIMEOUT}); do
          sleep 1
          if ${BASEDIR}/bin/mysqladmin -uroot -S$node/n${j}.sock ping > /dev/null 2>&1; then
            break
          fi
          if ! ${BASEDIR}/bin/mysqladmin -uroot -S$node/n${j}.sock ping > /dev/null 2>&1; then
            echo "ERROR! ${NODE_NAME} startup failed. Please check error log $node/error.err"
            exit 1
          fi
        done
        sudo pmm-admin add mysql ${NODE_NAME}-${j} --socket=$node/n${j}.sock --user=root --query-source=perfschema
      done
    fi
  done
}

if [ ! -z $list ]; then
  sudo pmm-admin list
fi

if [ ! -z $clean ]; then
  #Shutdown all mysql client instances
  for i in $(sudo pmm-admin list | grep "mysql:metrics" | sed 's|.*(||;s|)||') ; do
    mysqladmin -uroot --socket=${i} shutdown
  done
  #Kills mongodb processes
  sudo killall mongod 2> /dev/null
  sleep 5
  #Remove all client instances
  sudo pmm-admin remove --all
fi

if [ ${#ADDCLIENT[@]} -ne 0 ]; then
  add_ps_client
fi


