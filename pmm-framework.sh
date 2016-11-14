#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# Additions by Roel Van de Paar, Percona LLC

# PMM Framework
# This script enables one to quickly setup a Percona Monitoring and Management environment. One can setup a PMM server and qucikyl add multiple clients
# The intention of this script is to be robust from a quality assurance POV; it should handle many different server configurations accurately

# User configurable variables
PMM_VERSION="1.0.5"

# Internatl variables
WORKDIR=${PWD}
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
SERVER_START_TIMEOUT=100

# Dispay script usage details
usage () {
  echo "Usage: [ options ]"
  echo "Options:"
    echo " --setup                   This will setup and configure a PMM server"
    echo " --addclient=ps,2          Add Percona (ps), MySQL (ms), MariaDB (md), and/or mongodb (mo) pmm-clients to the currently live PMM server (as setup by --setup)"
    echo "                           You can add multiple client instances simultaneously. eg : --addclient=ps,2  --addclient=ms,2 --addclient=md,2 --addclient=mo,2" 
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options= --longoptions=addclient:,setup,help \
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
    --help )
    usage
    exit 0
    ;;
  esac
done

if [ ! -z $setup ]; then
  #PMM configuration setup
  #PMM sanity check
  if docker ps | grep 'pmm-server' > /dev/null ; then
    echo "ERROR! pmm-server docker container is alreay runnning. Terminating"
    exit 1
  elif  docker ps -a | grep 'pmm-server' > /dev/null ; then
    CONTAINER_NAME=$(docker ps -a | grep 'pmm-server' | grep $PMM_VERSION | grep -v pmm-data | awk '{ print $1}')
    echo "ERROR! The name 'pmm-server' is already in use by container $CONTAINER_NAME"
    exit 1
  fi

  echo "Initiating PMM configuration"
  sudo docker create -v /opt/prometheus/data -v /opt/consul-data -v /var/lib/mysql --name pmm-data percona/pmm-server:$PMM_VERSION /bin/true 2>/dev/null 
  docker run -d -p 80:80 --volumes-from pmm-data --name pmm-server --restart always percona/pmm-server:$PMM_VERSION 2>/dev/null

  if [[ ! -e `which pmm-admin 2> /dev/null` ]] ;then
    echo "ERROR! The pmm-admin client binary was not found, please install the pmm-admin client package"  
    exit 1
  else
    PMM_ADMIN_VERSION=`sudo pmm-admin --version`
    if [ "$PMM_ADMIN_VERSION" != "$PMM_VERSION" ]; then
      echo "ERROR! The pmm-admin client version is $PMM_ADMIN_VERSION. Required version is $PMM_VERSION"  
      exit 1
    else
      IP_ADDRESS=`ip route get 8.8.8.8 | head -1 | cut -d' ' -f8`
      sudo pmm-admin config --server $IP_ADDRESS
    fi
  fi
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
      if [ ! -z $BASEDIR ]; then
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
      if [ ! -z $BASEDIR ]; then
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
      if [ ! -z $BASEDIR ]; then
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
    elif [[ "${CLIENT_NAME}" == "mo" ]]; then
      if [[ ! -e `which mlaunch 2> /dev/null` ]] ;then
        echo "WARNING! The mlaunch mongodb spin up local test environments tool is not installed. Configuring MondoDB server manually"
      else
        MTOOLS_MLAUNCH=`which mlaunch`
      fi
      BASEDIR=`ls -1td percona-server-mongodb-* | grep -v ".tar" | head -n1`
      if [ ! -z $BASEDIR ]; then
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
        node="${BASEDIR}/node$j"
        if [ "$(${BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
          mkdir -p $node
          ${MID} --datadir=$node  > ${BASEDIR}/startup_node$j.err 2>&1
        else
          if [ ! -d $node ]; then
            ${MID} --datadir=$node  > ${BASEDIR}/startup_node$j.err 2>&1
          fi
        fi
        ${BASEDIR}/bin/mysqld --no-defaults --basedir=${BASEDIR} --datadir=$node --log-error=$node/error.err \
          --socket=$node/n${j}.sock --port=$RBASE1  > $node/error.err 2>&1 &
        for X in $(seq 0 ${SERVER_START_TIMEOUT}); do
          sleep 1
          if ${BASEDIR}/bin/mysqladmin -uroot -S$node/n${j}.sock ping > /dev/null 2>&1; then
            break
          fi
        done
        sudo pmm-admin add mysql ${NODE_NAME}-${j} --socket=$node/n${j}.sock --user=root --query-source=perfschema
      done
    fi
  done
}

if [ ${#ADDCLIENT[@]} -ne 0 ]; then
  add_ps_client
fi


