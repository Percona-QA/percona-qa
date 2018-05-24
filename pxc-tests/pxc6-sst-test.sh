#!/bin/bash -ue

# Author: Raghavendra Prabhu

set +e
echo "Killing existing mysqld"
pgrep -f mysqld

pkill -f mysqld
sleep 10
pgrep mysqld || pkill -9 -f mysqld

set -e

sleep 5

XB_VER=2.2
WORKDIR=$1
cd $WORKDIR

FAILEDTESTS=""
DISTESTS=""
ADDNLOP=${ADDNLOP:-""}

export ADDNLOP
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

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster*.tar.gz | head -n1`
BASE="$(basename $TAR .tar.gz)"
tar -xf $TAR

TAR=`ls -1ct percona-xtrabackup*.tar.gz | head -n1`
#BBASE="$(basename $TAR .tar.gz)"
tar -xf $TAR

for ver in {20..0};do
    BBASE=`ls  -d percona-xtrabackup*-Linux-$(uname -m)`
    if [[ -d $BBASE ]];then
        XB_VER=2.2.$ver
        break
    fi
done

if [[ $ver -eq 0 ]];then
    echo "FATAL: No suitable Xtrabackup artifact found"
    exit 2
fi

if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1
  rm -Rf ${BUILD_NUMBER}/*
fi

BUILD_WIPE=$[ ${BUILD_NUMBER} - 5 ]
if [ -d ${BUILD_WIPE} ]; then rm -Rf ${BUILD_WIPE}; fi

mkdir ${BUILD_NUMBER}
export ROOT_FS="$WORKDIR/${BUILD_NUMBER}"

mv $BASE $ROOT_FS/
mv $BBASE $ROOT_FS/
[ -e "qpress" ] && mv qpress $ROOT_FS/

rm -rf /tmp/blog1 /tmp/blog2 || true
mkdir -p /tmp/blog1 /tmp/blog2

touch /tmp/blog1/TESTFILE
touch /tmp/blog2/TESTFILE

#rm *.tar.gz

cd ${BUILD_NUMBER}


mkdir -p $ROOT_FS/tmp

export PATH="$ROOT_FS/$BBASE/bin:$ROOT_FS:$PATH"

MYSQL_BASEDIR="${ROOT_FS}/$BASE"
#export XB_TESTDIR="$ROOT_FS/$BBASE/share/percona-xtrabackup-test/"
export XB_TESTDIR="$ROOT_FS/$BASE/percona-xtradb-cluster-tests/"
#trap "cp -R $XB_TESTDIR/results $WORKDIR/results-${BUILD_NUMBER}" EXIT
trap "cp -R $XB_TESTDIR/results $WORKDIR/results-${BUILD_NUMBER} && tar czf $WORKDIR/results-${BUILD_NUMBER}.tar.gz $WORKDIR/results-${BUILD_NUMBER} " EXIT KILL

cp -R $XB_TESTDIR/certs /tmp/

echo "Workdir: $ROOT_FS"
echo "Basedir: $MYSQL_BASEDIR"

cd $XB_TESTDIR

echo "PATH $PATH"
echo "XB_TESTDIR $XB_TESTDIR"

if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    bash -x ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst.sh
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

    t+=" with $CONF"
    echo "Running test $t"
    if [[ $t == *rlimit* ]];then
        export PING_ATTEMPTS=130
    else
        export PING_ATTEMPTS=100
    fi

    set +e
    if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
        bash -x ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_advanced-v2.sh
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

unset CONF

echo "Running test for SST special dirs with encrypt=1"

t="SST special dirs with encrypt=1"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    bash -x ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
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
    bash -x ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
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
    bash -x ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
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
    bash -x ./run.sh -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
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
    bash -x ./run.sh -c galera55 -d $MYSQL_BASEDIR -t t/xb_galera_sst_dirs.sh
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

t="Encrypted replication and encrypted SST"
set +e
if [[ -n ${SST_DEBUG:-} && $SST_DEBUG == '2' ]];then
    bash -x ./run.sh  -d $MYSQL_BASEDIR -t t/xb_galera_sst_encrypted.sh
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
