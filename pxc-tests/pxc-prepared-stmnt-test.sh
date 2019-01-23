#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script is made for PXC Prepared SQL Statement test

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "./pxc-prepared-stmnt-test.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH                     Specify work directory"
  echo "  -b, --build-number=NUMBER              Specify work build directory"
  echo "  -s, --sst-method=[rsync|xtrabackup-v2] Specify SST method for cluster data transfer"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:s:h --longoptions=workdir:,build-number:,sst-method:,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- "$go_out"
fi

if [[ $go_out == " --" ]];then
  usage
  exit 1
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -w | --workdir )
    export WORKDIR="$2"
    if [[ ! -d "$WORKDIR" ]]; then
      echo "ERROR: Workdir ($WORKDIR) directory does not exist. Terminating!"
      exit 1
    fi
    shift 2
    ;;
    -b | --build-number )
    export BUILD_NUMBER="$2"
    shift 2
    ;;
    -s | --sst-method )
    export SST_METHOD="$2"
    shift 2
    if [[ "$SST_METHOD" != "rsync" ]] && [[ "$SST_METHOD" != "xtrabackup-v2" ]] ; then
      echo "ERROR: Invalid --sst-method passed:"
      echo "  Please choose any of these sst-method options: 'rsync' or 'xtrabackup-v2'"
      exit 1
    fi
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

#Format version string (thanks to wsrep_sst_xtrabackup-v2) 
normalize_version(){
  local major=0
  local minor=0
  local patch=0
  
  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  fi
  printf %02d%02d%02d $major $minor $patch
}

#Version comparison script (thanks to wsrep_sst_xtrabackup-v2) 
check_for_version()
{
  local local_version_str="$( normalize_version $1 )"
  local required_version_str="$( normalize_version $2 )"
  
  if [[ "$local_version_str" < "$required_version_str" ]]; then
    return 1
  else
    return 0
  fi
}

# generic variables
if [[ -z "$WORKDIR" ]]; then
  export WORKDIR=${PWD}
fi
ROOT_FS=$WORKDIR
if [[ -z "$SST_METHOD" ]]; then
  export SST_METHOD="xtrabackup-v2"
fi
if [[ -z ${BUILD_NUMBER} ]]; then
  BUILD_NUMBER=1001
fi

cd $ROOT_FS
WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

SCRIPT_PWD=$(cd `dirname $0` && pwd)

#Check PXC binary tar ball
PXC_TAR=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep ".tar" | head -n1`
if [[ ! -z $PXC_TAR ]];then
  tar -xzf $PXC_TAR
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
else
  PXCBASE=`ls -1td ?ercona-?tra??-?luster* 2>/dev/null | grep -v ".tar" | head -n1`
  if [[ -z $PXCBASE ]] ; then
    echoit "ERROR! Could not find PXC base directory."
    exit 1
  else
    export PATH="$ROOT_FS/$PXCBASE/bin:$PATH"
  fi
fi
PXCBASEDIR="${ROOT_FS}/$PXCBASE"
declare MYSQL_VERSION=$(${PXC_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

# Setting xtrabackup SST method
if [[ $SST_METHOD == "xtrabackup-v2" ]];then
  PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
  if [ ! -z $PXB_BASE ];then
    export PATH="$ROOT_FS/$PXB_BASE/bin:$PATH"
  else
    if check_for_version $MYSQL_VERSION "8.0.0" ; then
      wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-8.0.4/binary/tarball/percona-xtrabackup-8.0.4-Linux-x86_64.libgcrypt20.tar.gz
    else
      wget https://www.percona.com/downloads/XtraBackup/Percona-XtraBackup-2.4.13/binary/tarball/percona-xtrabackup-2.4.13-Linux-x86_64.libgcrypt20.tar.gz
    fi
    tar -xzf percona-xtrabackup*.tar.gz
    PXB_BASE=`ls -1td percona-xtrabackup* | grep -v ".tar" | head -n1`
    export PATH="$ROOT_FS/$PXB_BASE/bin:$PATH"
  fi
fi

EXTSTATUS=0

#mysql install db check

if check_for_version $MYSQL_VERSION "5.7.0" ; then
  MID="${PXCBASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PXCBASEDIR}"
else
  MID="${PXCBASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PXCBASEDIR}"
fi

archives() {
    tar czf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap archives EXIT KILL

ps -ef | grep 'node[1-9].sock' | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

check_server_startup(){
  node=$1
  echo "Waiting for ${node} to start ....."
  while true ; do
    sleep 3
	if ${PXCBASEDIR}/bin/mysqladmin -uroot --socket=/tmp/$node.sock ping > /dev/null 2>&1; then
      break
    fi
    if [ "${MPID}" == "" ]; then
      echo "Error! server not started.. Terminating!"
      egrep -i "ERROR|ASSERTION" ${WORKDIR}/logs/${node}.err
      exit 1
    fi
  done
}

pxc_startup(){
  ADDR="127.0.0.1"
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE1="$(( RPORT*1000 ))"
  RADDR1="$ADDR:$(( RBASE1 + 7 ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"

  RBASE2="$(( RBASE1 + 100 ))"
  RADDR2="$ADDR:$(( RBASE2 + 7 ))"
  LADDR2="$ADDR:$(( RBASE2 + 8 ))"

  RBASE3="$(( RBASE1 + 200 ))"
  RADDR3="$ADDR:$(( RBASE3 + 7 ))"
  LADDR3="$ADDR:$(( RBASE3 + 8 ))"

  SUSER=root
  SPASS=

  node1="${WORKDIR}/node1"
  node2="${WORKDIR}/node2"
  node3="${WORKDIR}/node3"
  rm -Rf $node1 $node2 $node3
  if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
    mkdir -p $node1 $node2 $node3
  fi
  MPID_ARRAY=()

  echo "Starting PXC node1"
  ${MID} --datadir=$node1  > ${WORKDIR}/logs/node1.err 2>&1

  STARTUP_OPTIONS="--max-connections=2048 --innodb_autoinc_lock_mode=2  --wsrep-provider=${PXCBASEDIR}/lib/libgalera_smm.so --wsrep_node_incoming_address=$ADDR --wsrep_sst_method=$SST_METHOD --wsrep_sst_auth=$SUSER:$SPASS --wsrep_node_address=$ADDR --innodb_flush_method=O_DIRECT --core-file --secure-file-priv= --wsrep_slave_threads=3 --log-output=none"

  CMD="${PXCBASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${PXCBASEDIR} --datadir=$node1 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 --log-error=${WORKDIR}/logs/node1.err --socket=/tmp/node1.sock --port=$RBASE1 --server-id=1"

  echo $CMD > ${WORKDIR}/node1_startup 2>&1
  $CMD --wsrep-new-cluster > ${WORKDIR}/logs/node1.err 2>&1 &

  MPID="$!"
  MPID_ARRAY+=(${MPID})
  check_server_startup node1

  echo "Starting PXC node2"
  ${MID} --datadir=$node2  > ${WORKDIR}/logs/node2.err 2>&1 || exit 1;

  CMD="${PXCBASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${PXCBASEDIR} --datadir=$node2 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR2 --log-error=${WORKDIR}/logs/node2.err --socket=/tmp/node2.sock --log-output=none --port=$RBASE2 --server-id=2"

  echo $CMD > ${WORKDIR}/node2_startup 2>&1
  $CMD > ${WORKDIR}/logs/node2.err 2>&1 &
  MPID="$!"
  MPID_ARRAY+=(${MPID})
  check_server_startup node2

  echo "Starting PXC node3"
  ${MID} --datadir=$node3  > ${WORKDIR}/logs/node3.err 2>&1 || exit 1;

  CMD="${PXCBASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${PXCBASEDIR} --datadir=$node3 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR3 --log-error=${WORKDIR}/logs/node3.err --socket=/tmp/node3.sock --log-output=none --port=$RBASE3 --server-id=3"

  echo $CMD > ${WORKDIR}/node3_startup 2>&1
  $CMD  > ${WORKDIR}/logs/node3.err 2>&1 &
  # ensure that node-3 has started and has joined the group post SST
  MPID="$!"
  MPID_ARRAY+=(${MPID})
  check_server_startup node3

  if ${PXCBASEDIR}/bin/mysqladmin -uroot --socket=/tmp/node1.sock ping > /dev/null 2>&1; then
    echo 'Started PXC node1...'
    ${PXCBASEDIR}/bin/mysql -uroot --socket=/tmp/node1.sock -e"CREATE DATABASE IF NOT EXISTS test" > /dev/null 2>&1
  else
    echo 'PXC node1 not stated...'
  fi
  if ${PXCBASEDIR}/bin/mysqladmin -uroot --socket=/tmp/node2.sock ping > /dev/null 2>&1; then
    echo 'Started PXC node2...'
  else
    echo 'PXC node2 not stated...'
  fi
  if ${PXCBASEDIR}/bin/mysqladmin -uroot --socket=/tmp/node3.sock ping > /dev/null 2>&1; then
    echo 'Started PXC node3...'
  else
    echo 'PXC node3 not stated...'
  fi
}

pxc_startup
check_script(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echo "Assert! ${MPID}. Terminating!"; exit 1; fi
}

#Initiate PXC prepared statement
${PXCBASEDIR}/bin/mysql  -uroot -S/tmp/node1.sock -e"source $SCRIPT_PWD/prepared_statements.sql" 2>/dev/null 2>&1 &
sleep 60
echo "Starting single node recovery test"
kill -9 ${MPID_ARRAY[2]}
sleep 10
STARTUP_NODE3=$(cat $WORKDIR/node3_startup)
$STARTUP_NODE3  > ${WORKDIR}/logs/node3.err 2>&1 &
MPID="$!"
MPID_ARRAY[2]=$MPID
check_server_startup node3
echo "PXC prepared statement recovery test completed"

echo "Adding new node to cluster"
node4="${WORKDIR}/node4"
rm -Rf $node4
mkdir -p $node4
RBASE4="$(( RBASE1 + 300 ))"
RADDR4="$ADDR:$(( RBASE4 + 7 ))"
LADDR4="$ADDR:$(( RBASE4 + 8 ))"
${MID} --datadir=$node4  > ${WORKDIR}/logs/node4.err 2>&1

CMD="${PXCBASEDIR}/bin/mysqld --no-defaults $STARTUP_OPTIONS --basedir=${PXCBASEDIR} --datadir=$node4 --wsrep_cluster_address=gcomm://$LADDR1,gcomm://$LADDR2,gcomm://$LADDR3,gcomm://$LADDR4 --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR4 --log-error=${WORKDIR}/logs/node4.err --socket=/tmp/node4.sock --log-output=none --port=$RBASE4 --server-id=4"

$CMD  > ${WORKDIR}/logs/node4.err 2>&1 &

check_server_startup node4
if ${PXCBASEDIR}/bin/mysqladmin -uroot --socket=/tmp/node4.sock ping > /dev/null 2>&1; then
  echo 'Started PXC node4...'
else
  echo 'PXC node4 not stated...'
fi

sleep 100

${PXCBASEDIR}/bin/mysqladmin  --socket=/tmp/node4.sock  -u root shutdown
${PXCBASEDIR}/bin/mysqladmin  --socket=/tmp/node3.sock  -u root shutdown
${PXCBASEDIR}/bin/mysqladmin  --socket=/tmp/node2.sock  -u root shutdown
${PXCBASEDIR}/bin/mysqladmin  --socket=/tmp/node1.sock  -u root shutdown

exit $EXTSTATUS

