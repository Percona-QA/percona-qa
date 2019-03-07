#!/bin/bash -ue
# Created by Raghavendra Prabhu
# Updated by Ramesh Sivaraman, Percona LLC
# This script will test the data consistency between Percona XtraDB Cluster nodes.

# Dispay script usage details
usage () {
  echo "Usage:"
  echo "  pxc-correctness-testing.sh  --workdir=PATH"
  echo ""
  echo "Additional options:"
  echo "  -w, --workdir=PATH           Specify work directory"
  echo "  -b, --build-number=NUMBER    Specify work build directory"
  echo "  -x, --xb-version=VERSION     Specify xtrabackup version"
  echo "  -k, --with-keyring-plugin    Run the script with keyring-file plugin"
  echo "  -e, --with-binlog-encryption Run the script with binary log encryption feature"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=w:b:x:keh --longoptions=workdir:,build-number:,xb-version:,with-keyring-plugin,with-binlog-encryption,help \
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
    -e | --with-binlog-encryption )
    shift
    export BINLOG_ENCRYPTION=1
    ;;
    -k | --with-keyring-plugin )
    shift
    export KEYRING_PLUGIN=1
        ;;
    -x | --xb-version )
    export XB_VERSION="$2"
    shift 2
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

set +e
echo "Killing existing mysqld"
pgrep -f mysqld

pkill -f mysqld
sleep 10
pgrep mysqld || pkill -9 -f mysqld

set -e

sleep 5

# generic variables
if [[ -z ${WORKDIR:-} ]]; then
  export WORKDIR=${PWD}
fi
ROOT_FS=$WORKDIR

if [[ -z ${XB_VERSION:-} ]]; then
  export XB_VERSION=2.4
fi
if [ -z ${BUILD_NUMBER:-} ]; then
  BUILD_NUMBER=1001
fi

if [[ ${KEYRING_PLUGIN:-} -eq 1 ]]; then
  export EXTRA_ENCRIPTION_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=keyring"
fi

if [[ ${BINLOG_ENCRYPTION:-} -eq 1 ]];then
  if [[ -z ${KEYRING_PLUGIN:-} ]]; then
    export EXTRA_ENCRIPTION_OPTIONS="--early-plugin-load=keyring_file.so --keyring_file_data=keyring"
  fi
  export EXTRA_ENCRIPTION_OPTIONS="$EXTRA_ENCRIPTION_OPTIONS --encrypt_binlog --master_verify_checksum=on --binlog_checksum=crc32 --innodb_encrypt_tables=ON"
fi

cd $WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)

FAILEDTESTS=""
DISTESTS=""

GVER="galera${GALERA_VER:-2}"

count=$(ls -1ct Percona-XtraDB-Cluster*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then
    for dirs in `ls -1ct Percona-XtraDB-Cluster*.tar.gz | tail -n +2`;do
        rm -rf $dirs
    done
fi

echo "Removing older core files, if any"
rm -f ${WORKDIR}/**/*core*

echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+

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

BUILD_WIPE=$[ ${BUILD_NUMBER} - 5 ]
if [ -d ${BUILD_WIPE} ]; then rm -Rf ${BUILD_WIPE}; fi
mkdir ${BUILD_NUMBER}
export ROOT_FS="$WORKDIR/${BUILD_NUMBER}"
MYSQL_BASEDIR="${ROOT_FS}/$PXCBASE"
declare MYSQL_VERSION=$(${MYSQL_BASEDIR}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
  #Check PXB binary tar ball
  PXB_TAR=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep ".tar" | head -n1`
  if [[ ! -z $PXB_TAR ]];then
    tar -xzf $PXB_TAR
    PXBBASE=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep -v ".tar" | head -n1`
    export PATH="$ROOT_FS/$PXBBASE/bin:$PATH"
  else
    PXBBASE=`ls -1td ?ercona-?trabackup* 2>/dev/null | grep -v ".tar" | head -n1`
    if [[ -z $PXBBASE ]] ; then
      echoit "ERROR! Could not find PXB base directory."
      exit 1
    else
      export PATH="$ROOT_FS/$PXBBASE/bin:$PATH"
    fi
  fi
fi

mv $PXCBASE $ROOT_FS/
if ! check_for_version $MYSQL_VERSION "8.0.0" ; then 
  mv $PXBBASE $ROOT_FS/
fi
[ -e "qpress" ] && mv qpress $ROOT_FS/

rm -rf /tmp/blog1 /tmp/blog2 || true
mkdir -p /tmp/blog1 /tmp/blog2

touch /tmp/blog1/TESTFILE
touch /tmp/blog2/TESTFILE

#rm *.tar.gz

cd ${BUILD_NUMBER}


mkdir -p $ROOT_FS/tmp

export XB_TESTDIR="${MYSQL_BASEDIR}/percona-xtradb-cluster-tests/sst"

#export XB_TESTDIR="$ROOT_FS/$BBASE/share/percona-xtrabackup-test/"
#export XB_TESTDIR="${SCRIPT_PWD}/percona-xtradb-cluster-tests/sst"
trap "cp -R $XB_TESTDIR/results $WORKDIR/results-${BUILD_NUMBER} && tar czf $WORKDIR/results-${BUILD_NUMBER}.tar.gz $WORKDIR/results-${BUILD_NUMBER} " EXIT KILL

cp -R $XB_TESTDIR/certs /tmp/

#cp $MYSQL_BASEDIR/lib/$GVER/libgalera_smm.so $MYSQL_BASEDIR/lib/

echo "Workdir: $ROOT_FS"
echo "Basedir: $MYSQL_BASEDIR"

cd $XB_TESTDIR

echo "PATH $PATH"
echo "XB_TESTDIR $XB_TESTDIR"

if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst.sh
else
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst.sh
fi

#exit

if [[ -n ${SST_DEBUG:-} ]];then
    set -x
fi

echo "Running advanced tests"

NUMTESTS=$(ls $XB_TESTDIR/conf/conf* | wc -l)
NUMTESTS=$(( NUMTESTS/2 ))

if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    sed -i -e '2 i\
        set -x' $MYSQL_BASEDIR/bin/wsrep_sst_xtrabackup
fi


for tn in `seq 1 $NUMTESTS`; do
    export CONF="conf${tn}"
    t=$(head -1 $XB_TESTDIR/conf/conf${tn}.cnf-node1  | tr -d '#')
    if [[ $DISTESTS == *$CONF* ]];then
        echo "Skipping test $t"
        continue
    fi

    if grep -qE '56only' $XB_TESTDIR/conf/conf${tn}.cnf-node1;then
        echo "Skipping test $t since it is 56only"
        continue
    fi

    t+=" with $CONF"
    echo "Running test $t"
    if [[ $t == *rlimit* ]];then
        export PING_ATTEMPTS=130
    else
        export PING_ATTEMPTS=100
    fi
    if [[ "$t" == *"encrypt"* ]];then
        if [[ ! -z ${EXTRA_ENCRIPTION_OPTIONS:-} ]];then
          echo "This run will initiate with keyring-file plugin/data-at-rest encryption options"
          export KEYRING_ENCRIPTION_OPTIONS="$EXTRA_ENCRIPTION_OPTIONS"
        fi
    fi
    set +e
    if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
        ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced-v2.sh
    elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
        ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced-v2.sh
    else
        ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced-v2.sh
    fi

    if [[ $? -ne 0 ]];then
        FAILEDTESTS+="Test $t failed\n"
    fi
    set -e

    if [[ $t == *progressfile* ]];then
        set +e
        mv /tmp/progress1-$CONF.log $XB_TESTDIR/results/
        mv /tmp/progress2-$CONF.log $XB_TESTDIR/results/
        set -e
    fi
done


for tn in `seq 1 $NUMTESTS`; do
    export CONF="conf${tn}"
    t=$(head -1 $XB_TESTDIR/conf/conf${tn}.cnf-node1  | tr -d '#')
    if [[ $DISTESTS == *$CONF* ]];then
        echo "Skipping test $t"
        continue
    fi

    if grep -qE 'v2only|56only' $XB_TESTDIR/conf/conf${tn}.cnf-node1;then
        echo "Skipping test $t since it is v2only|56only"
        continue
    fi

    t+=" with $CONF"
    echo "Running test $t"
    if [[ $t == *rlimit* ]];then
        export PING_ATTEMPTS=130
    else
        export PING_ATTEMPTS=100
    fi
    if [[ "$t" == *"encrypt"* ]];then
        if [[ ! -z ${EXTRA_ENCRIPTION_OPTIONS:-} ]];then
          echo "This run will initiate with keyring-file plugin/data-at-rest encryption options"
          export KEYRING_ENCRIPTION_OPTIONS="$EXTRA_ENCRIPTION_OPTIONS"
        fi
    fi
    set +e
    if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
        ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced.sh
    elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
        ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced.sh
    else
        ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced.sh
    fi

    if [[ $? -ne 0 ]];then
        FAILEDTESTS+="Test $t failed\n"
    fi
    set -e

    if [[ $t == *progressfile* ]];then
        set +e
        mv /tmp/progress1-$CONF.log $XB_TESTDIR/results/
        mv /tmp/progress2-$CONF.log $XB_TESTDIR/results/
        set -e
    fi
done

unset CONF

echo "Running test for SST special dirs with encrypt=1"

t="SST special dirs with encrypt=1"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
else
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
fi

if [[ $? -ne 0 ]];then
    FAILEDTESTS+="Test $t failed\n"
fi
set -e


echo "Running test for SST special dirs with encrypt=2"

export CONF=bug1098566-1
t="SST special dirs with encrypt=2 with $CONF"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
else
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
fi

if [[ $? -ne 0 ]];then
    FAILEDTESTS+="Test $t failed\n"
fi
unset CONF
set -e


echo "Running test for SST special dirs with encrypt=3"

export CONF=bug1098566-2
t="SST special dirs with encrypt=3 with $CONF"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
else
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
fi

if [[ $? -ne 0 ]];then
    FAILEDTESTS+="Test $t failed\n"
fi
unset CONF
set -e


echo "Running test for SST special dirs with encrypt=1 and innobackupex options"

export CONF=bug1098566-3
t="SST special dirs with encrypt=1 and inno-backup opts with $CONF"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
else
    ./run.sh -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
fi

if [[ $? -ne 0 ]];then
    FAILEDTESTS+="Test $t failed\n"
fi
unset CONF
set -e


echo "Running test for SST special dirs with undo-log-directory"

export CONF=bug1394836
t="SST special dirs with undo-log-directory with $CONF"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
else
    ./run.sh -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
fi

if [[ $? -ne 0 ]];then
    FAILEDTESTS+="Test $t failed\n"
fi
unset CONF
set -e



echo "Running test for encrypted replication and SST"
if [[ ! -z ${EXTRA_ENCRIPTION_OPTIONS:-} ]];then
  echo "This run will initiate with keyring-file plugin/data-at-rest encryption options"
fi

t="Encrypted replication and encrypted SST"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_encrypted.sh
elif [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '30' ]];then
    ./run.sh -g  -d $MYSQL_BASEDIR -t t/xb_galera_sst_encrypted.sh
else
    ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_encrypted.sh
fi
if [[ $? -ne 0 ]];then
    FAILEDTESTS+="Test $t failed\n"
fi
set -e


if [[ -n $FAILEDTESTS ]];then
    echo "Following tests unsuccessful"
    echo -e "$FAILEDTESTS"
    exit 1
fi

if [[ ! -e /tmp/blog1/TESTFILE || ! -e /tmp/blog2/TESTFILE ]];then
    echo "conf20 failed"
    exit 1
fi

rm -rf /tmp/blog1 /tmp/blog2 || true