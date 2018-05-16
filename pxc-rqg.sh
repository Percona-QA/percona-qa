#!/bin/bash -ue

# Author: Raghavendra Prabhu

ulimit -c unlimited
set +e
echo "Killing existing mysqld"
pgrep -f mysqld

pkill -f mysqld
pkill -f rsync
sleep 10
pgrep mysqld || pkill -9 -f mysqld
set -e

sleep 5

WORKDIR=$1
ROOT_FS=$WORKDIR
RUND=${RUND:-50000}
RUNT=${RUNT:-16}
TYPE=${GTYPE:-ms}
FMSG=""
CVARDIR=""
BVARDIR=""
GVER="galera${GALERA_VER:-2}"

status=""
ttype=""

if [[ -z $RPTR ]];then
    RPTR="Shutdown,Backtrace,ErrorLog,ErrorLogAlarm,Deadlock"
fi

if [[ -z ${EXTRAOPTS:-} ]];then
    EXTRAOPTS=""
fi

if [[ -z ${AUXOPTS:-} ]];then
    AUXOPTS=""
fi

exitc(){
    if [[ -d ${ROOT_FS}/results-${BUILD_NUMBER} ]];then
        tar czf ${ROOT_FS}/trial.tar.gz ${ROOT_FS}/results-${BUILD_NUMBER} || true
    fi
    if [[ -d ${ROOT_FS}/traces/traces-${BUILD_NUMBER} ]];then
        tar czf ${ROOT_FS}/traces.tar.gz ${ROOT_FS}/traces/traces-${BUILD_NUMBER} || true
    fi
    set +e
    pkill -f valgrind
    pkill -9 -f valgrind
    pkill  -f runall-new
    sleep 20
    pkill -9 -f runall-new
    pkill mysqld
    pkill -9  mysqld
    pkill timeout

    set -e

}

trap exitc EXIT KILL

failed(){
    exstatus=$?
    set +e

    set -x
    if [[ -n ${CVARDIR:-} ]];then
        if [[ $exstatus -ne 0 ]];then
            mkdir -p ${ROOT_FS}/traces/traces-${BUILD_NUMBER}/$ttype/logs
            mv gdb* trace* ${ROOT_FS}/traces/traces-${BUILD_NUMBER}/$ttype/ 2>/dev/null
            rsync -av --exclude='data' $CVARDIR/ ${ROOT_FS}/traces/traces-${BUILD_NUMBER}/$ttype/logs/ 2>/dev/null
        fi
    fi



    set +x
    echo "Exit status from last job: $exstatus"
    if [[ $exstatus -ne 0 ]];then
        echo "Killing existing mysqld"
        pkill -9 mysqld
        pkill -9 -f valgrind
        pkill -9 -f runall-new
        sleep 2
        pgrep mysqld
    fi
    echo
    echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
    echo "                     $status failed                   "
   echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
    echo
    FMSG+="$status : $exstatus \n"


    echo "INT. REPORT"

    echo
    echo "#################################################################################"
    echo
    echo -e "\n $FMSG \n"
    echo
    echo "#################################################################################"
    echo
    set -e
    set -x
}

pecho(){
    status="$1"
    echo $status
}

cd $WORKDIR


count=$(ls -1ct Percona-XtraDB-Cluster*.tar.gz | wc -l)

echo "Removing older tar.gz"
if [[ $count -gt 1 ]];then
    for dirs in `ls -1ct Percona-XtraDB-Cluster*.tar.gz | tail -n +2`;do
        rm -rf $dirs
    done
fi

echo "Removing older PXC directories"
find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster*' -exec rm -rf {} \+

echo "Removing older core files, if any"
rm -f ${ROOT_FS}/**/*core*

echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +4 -exec rm -rf {} \+

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +4 -delete

echo "Removing the older build directory"
rm -rf $ROOT_FS/$(( BUILD_NUMBER-1 )) || true



TAR=`ls -1ct Percona-XtraDB-Cluster*.tar.gz | head -n1`
BASE="$(tar tf $TAR | head -1 | tr -d '/')"


tar -xf $TAR


# Keep (PS & QA) builds & results for ~40 days (~1/day)
#BUILD_WIPE=$[ ${BUILD_NUMBER} - 40 ]
#if [ -d ${BUILD_WIPE} ]; then rm -Rf ${BUILD_WIPE}; fi


if [ -d pxcgen ];then
    touch -m pxcgen
    pushd pxcgen
    bzr pull
    popd
else
    bzr branch lp:~raghavendra-prabhu/randgen/pxc pxcgen
fi



WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR

MYSQL_BASEDIR="${ROOT_FS}/$BASE"
export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

cp $MYSQL_BASEDIR/lib/$GVER/libgalera_smm.so $MYSQL_BASEDIR/lib/


echo "Workdir: $WORKDIR"
echo "Basedir: $MYSQL_BASEDIR"


export GENDIR="${ROOT_FS}/pxcgen"

pushd $GENDIR

ADDR=127.0.0.1

mkdir -p ${ROOT_FS}/traces/traces-${BUILD_NUMBER}

set +e
set -x

if ! grep -q 'skip' <<< $REST;then
    pecho "Running with normal grammar "
    ttype="normal"
    CVARDIR=$(mktemp -d --tmpdir=$WORKDIR 'normal-XXX')
    timeout -s 11  $TTMT perl runall-new.pl --basedir=${MYSQL_BASEDIR} --vardir=$CVARDIR --galera=$GTYPE $EXTRAOPTS  --reporter=$RPTR --grammar=conf/galera/galera_stress.yy --gendata=conf/galera/galera_stress.zz --threads=$RUNT --queries=$RUND --mysqld=--wsrep-provider=$MYSQL_BASEDIR/lib/libgalera_smm.so --seed=time  --mysqld=--innodb_flush_method=O_DIRECT  || failed

    echo
    echo

    pecho "Running galera with normal + lock_wait_timeout"
    ttype="normaltmt"

    CVARDIR=$(mktemp -d --tmpdir=$WORKDIR 'normaltmt-XXX')
    timeout -s 11  $TTMT perl runall-new.pl --basedir=${MYSQL_BASEDIR} --vardir=$CVARDIR --galera=$GTYPE $EXTRAOPTS  --reporter=$RPTR --grammar=conf/galera/galera_stress.yy --gendata=conf/galera/galera_stress.zz --threads=$RUNT --queries=$RUND --mysqld=--wsrep-provider=$MYSQL_BASEDIR/lib/libgalera_smm.so  --mysqld=--innodb_flush_method=O_DIRECT  --mysqld=--lock_wait_timeout=50 --seed=time  || failed

    echo
    echo
    pecho "Running galera with complex grammar"
    ttype="complex"

    CVARDIR=$(mktemp -d --tmpdir=$WORKDIR 'complex-XXX')
    timeout -s 11  $TTMT perl runall-new.pl --basedir=${MYSQL_BASEDIR} --vardir=$CVARDIR --galera=$GTYPE $EXTRAOPTS  --reporter=$RPTR --grammar=conf/galera/galera_stress.yy --gendata=conf/galera/galera_stress-complex.zz --threads=$RUNT --queries=$RUND --mysqld=--wsrep-provider=$MYSQL_BASEDIR/lib/libgalera_smm.so  --mysqld=--innodb_flush_method=O_DIRECT  --seed=time  || failed

    echo
    echo
    pecho "Running galera with complex grammar and timeout"
    ttype="complextmt"

    CVARDIR=$(mktemp -d --tmpdir=$WORKDIR 'complextmt-XXX')
    timeout -s 11  $TTMT perl runall-new.pl --basedir=${MYSQL_BASEDIR} --vardir=$CVARDIR --galera=$GTYPE  $EXTRAOPTS --reporter=$RPTR --grammar=conf/galera/galera_stress.yy --gendata=conf/galera/galera_stress-complex.zz --threads=$RUNT --queries=$RUND --mysqld=--wsrep-provider=$MYSQL_BASEDIR/lib/libgalera_smm.so  --mysqld=--innodb_flush_method=O_DIRECT  --mysqld=--lock_wait_timeout=50 --seed=time  || failed

fi

if [[ -n ${REST:-} ]];then

    for xtest in `tr ':' '\n' <<< $REST`;do
        echo
        echo

        if [[ $xtest == 'skip' ]];then
            continue
        fi
        pecho "Running galera with $xtest"

        CVARDIR=$(mktemp -d --tmpdir=$WORKDIR "${xtest}-XXX")
        ttype="${xtest}"
        zzfile="galera_stress-56.zz"
        if [[ -e conf/galera/galera_stress-${xtest}.zz ]];then
            zzfile="galera_stress-${xtest}.zz"
        fi


        if [[ $xtest == 'dml' ]];then
            AUXOPTS+=" --mysqld=--innodb_locks_unsafe_for_binlog=ON "
        fi

        timeout -s 11  $TTMT perl runall-new.pl --basedir=${MYSQL_BASEDIR} --vardir=$CVARDIR --galera=$GTYPE $EXTRAOPTS $AUXOPTS --reporter=$RPTR --grammar=conf/galera/galera_stress-${xtest}.yy --gendata=conf/galera/$zzfile --threads=$RUNT --queries=$RUND --mysqld=--wsrep-provider=$MYSQL_BASEDIR/lib/libgalera_smm.so  --mysqld=--innodb_flush_method=O_DIRECT --seed=time  || failed
    done
fi
set +x
unset CVARDIR

echo
echo "REPORT"

echo
echo "#################################################################################"
echo
echo -e "\n $FMSG \n"
echo
echo "#################################################################################"
echo

if ! grep -q 'skip' <<< $REST;then
    pecho "Running combinations"

    # Internal settings
    MTR_BT=$[$RANDOM % 300 + 1]

    CWORKDIR=$(mktemp -d --tmpdir=$WORKDIR)
    BVARDIR=$(mktemp -d --tmpdir=$WORKDIR)

    ln -sf $BVARDIR ${ROOT_FS}/results-${BUILD_NUMBER}



    export MTR_BUILD_THREAD=$MTR_BT

    timeout 40m perl combinations.pl --basedir=${MYSQL_BASEDIR} --workdir=$CWORKDIR --vardir=$BVARDIR \
    --new  \
    --parallel=${RPARALLEL:-4} \
    --provider=${MYSQL_BASEDIR}/lib/libgalera_smm.so --galera=$GTYPE \
    --clean \
    --force \
    --config=conf/galera/galera_stress.cc \
    --grammar=conf/galera/galera_stress.yy \
    --gendata=conf/galera/galera_stress.zz \
    --seed=time \
    --trials=${RTRIALS:-10} \
    --duration=${RDURATION:-45} || failed
fi

echo
echo "REPORT"

echo
echo "#################################################################################"
echo
echo -e "\n $FMSG \n"
echo
echo "#################################################################################"
echo

if [[ -n $FMSG ]];then
    exit 1
fi



#echo "Running with galera grammar - subtest"
#perl runall-new.pl --basedir=${MYSQL_BASEDIR} --galera=ms --grammar=conf/galera/galera_stress-subselect.yy --gendata=conf/galera/galera_stress.zz --threads=16 --queries=1000 --mysqld=--wsrep-provider=$MYSQL_BASEDIR/lib/libgalera_smm.so --seed=time   || true
