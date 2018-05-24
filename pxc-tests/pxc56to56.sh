#!/bin/bash -ue

# Author: Raghavendra Prabhu
# TEST

ulimit -c unlimited
export MTR_MAX_SAVE_CORE=5

set +e
echo "Killing existing mysqld"
pgrep -f mysqld

pkill -f mysqld
sleep 10
pgrep mysqld || pkill -9 -f mysqld

set -e
sleep 5

LPATH=${SPATH:-/usr/share/doc/sysbench/tests/db}

WORKDIR=$1
ROOT_FS=$WORKDIR
sst_method=${SST_METHOD:-rsync}
thres=1

if [[ $sst_method == 'xtrabackup' ]];then
    wget -q  http://www.percona.com/redir/downloads/XtraBackup/LATEST/binary/tarball/percona-xtrabackup-2.2.3-4982-Linux-x86_64.tar.gz
    tar xf percona-xtrabackup-2.2.3-4982-Linux-x86_64.tar.gz
    export PATH="$PATH:$PWD/percona-xtrabackup-2.2.3-Linux-x86_64/bin/"
    sst_method='xtrabackup-v2'
fi

#pushd /tmp
#wget -q http://files.wnohang.net/files/libgalera_smm.so
#popd

cd $WORKDIR

VER2=`ls -1ct Percona-XtraDB-Cluster-* | cut -f4 -d'-' | grep -v '5.6.22'`
VER1=$(basename $RELEASE_BIN | cut -d- -f4)

if [[ $VER1 == $VER2 ]];then
    thres=2
fi

count=$(ls -1ct Percona-XtraDB-Cluster-$VER1*.tar.gz | wc -l)

if [[ $count -gt $thres ]];then
    for dirs in `ls -1ct Percona-XtraDB-Cluster-$VER1*.tar.gz | tail -n +2`;do
        rm -rf $dirs || true
    done
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-$VER1*' -exec rm -rf {} \+ || true



count=$(ls -1ct Percona-XtraDB-Cluster-$VER2*.tar.gz | wc -l)

if [[ $count -gt $thres ]];then
    for dirs in `ls -1ct Percona-XtraDB-Cluster-$VER2*.tar.gz | tail -n +2`;do
        rm -rf $dirs || true
    done
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-$VER2*' -exec rm -rf {} \+ || true


echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+ || true

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster-$VER2*.tar.gz | head -n1`
BASE2="$(tar tf $TAR | head -1 | cut -d '/' -f1)"

tar -xf $TAR


TAR=`ls -1ct Percona-XtraDB-Cluster-$VER1*.tar.gz | head -n1`
BASE1="$(tar tf $TAR | head -1 | cut -d '/' -f1)"

if [[ $BASE1 == $BASE2 ]];then
    TAR=`ls -1ct Percona-XtraDB-Cluster-$VER1*.tar.gz | tail -1`
    BASE1="$(tar tf $TAR | head -1 | cut -d '/' -f1)"
fi


if [[ $BASE1 == $BASE2 ]];then
    echo "FATAL: Failed"
    exit 1
fi

tar -xf $TAR
#cp -v /tmp/libgalera_smm.so $ROOT_FS/$BASE2/lib/galera3/



# Parameter of parameterized build
if [[ -n $SDURATION ]];then
    export SYSBENCH_DURATION=$SDURATION
else
    export SYSBENCH_DURATION=300
fi



WORKDIR="${ROOT_FS}/$BUILD_NUMBER"

for l in `seq $((BUILD_NUMBER - 2)) -1 1`;do
    rm -rf $l || true
done

mkdir -p $WORKDIR/logs

MYSQL_BASEDIR1="${ROOT_FS}/$BASE1"
MYSQL_BASEDIR2="${ROOT_FS}/$BASE2"
GALERA1="${MYSQL_BASEDIR1}/lib/libgalera_smm.so"
GALERA2="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"

if [[ ! -e $GALERA1 ]];then
    GALERA1="${MYSQL_BASEDIR1}/lib/galera3/libgalera_smm.so"
fi

if [[ ! -e $GALERA2 ]];then
    GALERA2="${MYSQL_BASEDIR2}/lib/galera3/libgalera_smm.so"
fi

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

SDIR="$LPATH"
SRESULTS="$WORKDIR/sresults"

mkdir -p $SRESULTS

echo "Workdir: $WORKDIR"
echo "Basedirs: $MYSQL_BASEDIR1 $MYSQL_BASEDIR2"



  ADDR="127.0.0.1"
  RPORT=$(( RANDOM%21 + 10 ))
  RBASE1="$(( RPORT*1000 ))"
  echo "Setting RBASE to $RBASE1"
  RADDR1="$ADDR:$(( RBASE1 + 7 ))"
  LADDR1="$ADDR:$(( RBASE1 + 8 ))"

  RBASE2="$(( RBASE1 + 100 ))"
  RADDR2="$ADDR:$(( RBASE2 + 7 ))"
  LADDR2="$ADDR:$(( RBASE2 + 8 ))"

  SUSER=root
  SPASS=

  node1="${MYSQL_VARDIR}/node1"
  mkdir -p $node1
  node2="${MYSQL_VARDIR}/node2"
  mkdir -p $node2

EXTSTATUS=0

if [[ $MEM -eq 1 ]];then
    MEMOPT="--mem"
else
    MEMOPT=""
fi

cleanup(){
    rm Percona-XtraDB-Cluster*.tar.gz*  || true
    tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}


trap cleanup EXIT KILL

if [[ -n ${EXTERNALS:-} ]];then
    EXTOPTS="$EXTERNALS"
else
    EXTOPTS=""
fi

if [[ $DIR -eq 1 ]];then
    sockets="$node1/socket.sock,$node2/socket.sock"
elif [[ $DIR -eq 2 ]];then
    sockets="$node2/socket.sock"
elif [[ $DIR -eq 3 ]];then
    sockets="$node1/socket.sock"
fi
STABLE="test.sbtest1"

if [[ $BUILD_SOURCE == 'debug' ]];then
    EXTOPTS+=" --mysqld=--skip-performance-schema "
fi
GDEBUG=""

if [[ $DEBUG -eq 1 ]];then
    DBG="--mysqld=--wsrep-debug=1"
elif [[ $DEBUG -eq 2 ]];then
    DBG=" --mysqld=--wsrep-debug=1 --mysqld=--wsrep-log-conflicts=ON "
elif [[ $DEBUG -eq 3 ]];then
    DBG=" --mysqld=--wsrep-debug=1 --mysqld=--wsrep-log-conflicts=ON"
    GDEBUG="; debug=1"
else
    DBG=""
fi

#export LD_LIBRARY_PATH="$MYSQL_BASEDIR1/lib"
SBENCH="sysbench"
common=" --start-and-exit --nowarnings  \
    --mysqld=--wsrep_sst_method=$sst_method \
    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
    --mysqld=--wsrep_node_address=$ADDR \
    --nodefault-myisam \
    --mysqld=--innodb_flush_method=O_DIRECT \
    --mysqld=--query_cache_type=0 \
    --mysqld=--query_cache_size=0 \
    --mysqld=--innodb_flush_log_at_trx_commit=0 \
    --mysqld=--innodb_buffer_pool_size=500M \
    --mysqld=--innodb_log_file_size=500M \
    --mysqld=--default-storage-engine=InnoDB \
    --mysqld=--loose-innodb \
    --mysqld=--sql-mode=no_engine_substitution \
    --mysqld=--skip-external-locking \
    --mysqld=--core-file \
    --mysqld=--skip-name-resolve \
    --mysqld=--innodb_file_per_table  \
    --mysqld=--binlog-format=ROW \
    --mysqld=--wsrep-slave-threads=8 \
    --mysqld=--innodb_autoinc_lock_mode=2 "

u_common=" --mysqld=--skip-grant-tables \
        --mysqld=--innodb_file_per_table  \
        --mysqld=--binlog-format=ROW \
        --mysqld=--innodb_autoinc_lock_mode=2 \
        --mysqld=--wsrep-provider=none \
        --mysqld=--innodb_flush_method=O_DIRECT \
        --mysqld=--query_cache_type=0 \
        --mysqld=--query_cache_size=0 \
        --mysqld=--innodb_flush_log_at_trx_commit=0 \
        --mysqld=--innodb_buffer_pool_size=500M \
        --mysqld=--innodb_log_file_size=500M \
        --mysqld=--skip-name-resolve \
        --mysqld=--default-storage-engine=InnoDB \
        --mysqld=--loose-innodb \
        --mysqld=--sql-mode=no_engine_substitution \
        --mysqld=--skip-external-locking \
        --start-and-exit \
        --start-dirty \
        --nowarnings \
        --nodefault-myisam "

ver_and_row(){
    local sock=$1


    $MYSQL_BASEDIR1/bin/mysql -S $sock  -u root -e "show global variables like 'version';"

    $MYSQL_BASEDIR1/bin/mysql -S $sock  -u root -e "select count(*) from $STABLE;"
    $MYSQL_BASEDIR1/bin/mysql -S $sock  -u root -e "select count(*) from $STABLE;"
}

prepare()
{
    local sock=$1
    local log=$2

    echo "Sysbench Run: Prepare stage"
    $SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-engine-trx=yes --mysql-table-engine=innodb \
        --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT \
        --db-driver=mysql --mysql-socket=$sock prepare 2>&1 | tee $log

    $MYSQL_BASEDIR1/bin/mysql  -S $sock -u root -e "create database testdb;" || true
}

rw_full()
{

    local sock=$1
    local log=$2
    echo "Sysbench Run: OLTP RW testing"
    $SBENCH --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --oltp-auto-inc=$AUTOINC --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
        --test=$SDIR/$STEST.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --mysql-db=test \
        --mysql-user=root --db-driver=mysql --mysql-socket=$sock  run 2>&1 | tee $log
}

rw_ist()
{
    local sock=$1
    local log=$2

    echo "Populating for IST"
    echo "Sysbench Run: OLTP RW testing"
        $SBENCH --mysql-table-engine=innodb --num-threads=1 --report-interval=10 --oltp-auto-inc=$AUTOINC --max-time=10 --max-requests=1870000000 \
            --test=$LPATH/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=$TCOUNT --mysql-db=test \
            --mysql-user=root --db-driver=mysql --mysql-socket=$sock  run 2>&1 | tee $log
}

get_script()
{

    if [[ ! -e $SDIR/${STEST}.lua ]];then
        pushd /tmp

        rm $STEST.lua || true
        wget -O $STEST.lua  https://github.com/Percona-QA/sysbench/tree/0.5/sysbench/tests/db/${STEST}.lua
        export SDIR=/tmp/
        popd
    fi

}

reset_compat()
{
    local gpath=$1
    if [[ $gpath == *galera3* ]];then
        COMPAT="; socket.checksum=1"
    else
        COMPAT=""
    fi
}


  reset_compat $GALERA1
  echo "Starting $VER1 node"
  pushd ${MYSQL_BASEDIR1}/mysql-test/
  perl mysql-test-run.pl \
    --mysqld=--basedir=${MYSQL_BASEDIR1} \
    --port-base=$RBASE1 \
    $common \
    --vardir=$node1 $DBG $MEMOPT $EXTOPTS \
    --mysqld=--wsrep-new-cluster \
    --mysqld=--wsrep-provider=$GALERA1 \
    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
    --mysqld=--wsrep_sst_receive_address=$RADDR1 \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${LADDR1}$COMPAT$GDEBUG" \
    --mysqld=--socket=$node1/socket.sock \
    --mysqld=--log-error=$WORKDIR/logs/node1.err \
    --mysqld=--log-output=none \
    1st
  popd


  prepare $node1/socket.sock $WORKDIR/logs/sysbench_prepare.txt

  reset_compat $GALERA2
  echo "Starting $VER2 node for SST"
    pushd ${MYSQL_BASEDIR2}/mysql-test/
    perl mysql-test-run.pl \
        --mysqld=--basedir=${MYSQL_BASEDIR2} \
        --port-base=$RBASE2 \
        $common \
        --vardir=$node2 $DBG $MEMOPT $EXTOPTS \
        --mysqld=--wsrep-provider=$GALERA2 \
        --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
        --mysqld=--wsrep_sst_receive_address=$RADDR2 \
        --mysqld=--wsrep_node_incoming_address=$ADDR \
        --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${LADDR2}$COMPAT$GDEBUG" \
        --mysqld=--socket=$node2/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node2-sst.err \
        --mysqld=--log-output=none \
        1st
    popd

    echo "Sleeping till SST is complete"
    sleep 10

    ver_and_row $node2/socket.sock
    ver_and_row $node1/socket.sock


    echo "Shutting down node2 after SST"
    ${MYSQL_BASEDIR1}/bin/mysqladmin  --socket=$node2/socket.sock -u root shutdown


    rw_ist $node1/socket.sock $WORKDIR/logs/sysbench_for_ist.txt




    sleep 10


  reset_compat $GALERA2
    pushd ${MYSQL_BASEDIR2}/mysql-test/
    echo "Restarting for IST"
    perl mysql-test-run.pl \
        --mysqld=--basedir=${MYSQL_BASEDIR2} \
        --start-dirty \
        --port-base=$RBASE2 \
        $common \
        --vardir=$node2 $DBG $MEMOPT $EXTOPTS \
        --mysqld=--wsrep-provider=$GALERA2 \
        --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
        --mysqld=--wsrep_sst_receive_address=$RADDR2 \
        --mysqld=--wsrep_node_incoming_address=$ADDR \
        --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${LADDR2}$COMPAT$GDEBUG" \
        --mysqld=--socket=$node2/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node2-ist.err \
        --mysqld=--log-output=none \
        1st
    popd

    sleep 10

    ver_and_row $node2/socket.sock
    ver_and_row $node1/socket.sock

    get_script

    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "create database testdb;" || true

    rw_full $sockets  $WORKDIR/logs/sysbench_rw_run.txt

    if [[ $VER1 > $VER2 ]];then
        node_for_upgrade=$VER2
        nodeu=$node2
        pbase=$RBASE2
        baseu=$MYSQL_BASEDIR1
        ugalera="${baseu}/lib/libgalera_smm.so"
        listu=$LADDR2
        recvu=$RADDR2
    else
        node_for_upgrade=$VER1
        nodeu=$node1
        pbase=$RBASE1
        baseu=$MYSQL_BASEDIR2
        ugalera="${baseu}/lib/libgalera_smm.so"
        listu=$LADDR1
        recvu=$RADDR1
    fi
    if [[ ! -e $ugalera ]];then
        ugalera="${baseu}/lib/galera3/libgalera_smm.so"
    fi

    echo "Shutting down $node_for_upgrade  for upgrade"
    $MYSQL_BASEDIR1/bin/mysqladmin  --socket=$nodeu/socket.sock -u root shutdown

    pushd ${baseu}/mysql-test/
    perl mysql-test-run.pl \
        --mysqld=--basedir=$baseu \
        --port-base=$pbase \
        $u_common \
        --vardir=$nodeu $DBG $MEMOPT $EXTOPTS \
        --mysqld=--socket=$nodeu/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node1-upgrade.err \
        --mysqld=--log-output=none \
        1st
    popd

    $baseu/bin/mysql_upgrade -S $nodeu/socket.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

    echo "Shutting down $node_for_upgrade after upgrade"
    $MYSQL_BASEDIR1/bin/mysqladmin  --socket=$nodeu/socket.sock -u root shutdown


    echo "Starting $node_for_upgrade after upgrade"


  reset_compat $ugalera
  pushd ${baseu}/mysql-test/
  perl mysql-test-run.pl \
    --mysqld=--basedir=$baseu \
    --port-base=$pbase \
    $common \
    --vardir=$nodeu $DBG $MEMOPT $EXTOPTS \
    --mysqld=--wsrep-provider=$ugalera \
    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
    --mysqld=--wsrep_sst_receive_address=$recvu \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${listu}$COMPAT$GDEBUG" \
    --mysqld=--socket=$nodeu/socket.sock \
    --mysqld=--log-error=$WORKDIR/logs/node1-postupgrade.err \
    --mysqld=--log-output=none \
    1st
  popd


    get_script

    rw_full $sockets  $WORKDIR/logs/sysbench_rw_run-2.txt


    sleep 100
    ver_and_row $node2/socket.sock
    ver_and_row $node1/socket.sock
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "drop database testdb;" || true
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "drop database test;"


    echo "Shutting down node2 "
    $MYSQL_BASEDIR2/bin/mysqladmin  --socket=$node2/socket.sock -u root shutdown

    sleep 10

    echo "Shutting down node1 "
    $MYSQL_BASEDIR2/bin/mysqladmin  --socket=$node1/socket.sock -u root shutdown


    echo "TESTING in reverse"


  node3="${MYSQL_VARDIR}/node3"
  mkdir -p $node3
  node4="${MYSQL_VARDIR}/node4"
  mkdir -p $node4

  MYSQL_BASEDIR1="${ROOT_FS}/$BASE2"
  MYSQL_BASEDIR2="${ROOT_FS}/$BASE1"
  GALERA1="${MYSQL_BASEDIR1}/lib/libgalera_smm.so"
  GALERA2="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
    if [[ ! -e $GALERA1 ]];then
        GALERA1="${MYSQL_BASEDIR1}/lib/galera3/libgalera_smm.so"
    fi

    if [[ ! -e $GALERA2 ]];then
        GALERA2="${MYSQL_BASEDIR2}/lib/galera3/libgalera_smm.so"
    fi

if [[ $DIR -eq 1 ]];then
    sockets="$node3/socket.sock,$node4/socket.sock"
elif [[ $DIR -eq 2 ]];then
    sockets="$node4/socket.sock"
elif [[ $DIR -eq 3 ]];then
    sockets="$node3/socket.sock"
fi

  VER1=$LATEST_VER
  VER2=$(basename $RELEASE_BIN | cut -d- -f4)

  echo "Starting $VER1 node"

  reset_compat $GALERA1
  pushd ${MYSQL_BASEDIR1}/mysql-test/
  perl mysql-test-run.pl \
    --mysqld=--basedir=${MYSQL_BASEDIR1} \
    --port-base=$RBASE1 \
    $common \
    --vardir=$node3 $DBG $MEMOPT $EXTOPTS \
    --mysqld=--wsrep-new-cluster \
    --mysqld=--wsrep-provider=$GALERA1 \
    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
    --mysqld=--wsrep_sst_receive_address=$RADDR1 \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${LADDR1}$COMPAT$GDEBUG" \
    --mysqld=--socket=$node3/socket.sock \
    --mysqld=--log-error=$WORKDIR/logs/node3.err \
    --mysqld=--log-output=none \
    1st
  popd

    prepare $node3/socket.sock $WORKDIR/logs/sysbench_prepare_r.txt

  reset_compat $GALERA2
  echo "Starting $VER2 node for SST"
    pushd ${MYSQL_BASEDIR2}/mysql-test/
    perl mysql-test-run.pl \
        --mysqld=--basedir=${MYSQL_BASEDIR2} \
        --port-base=$RBASE2 \
        $common \
        --vardir=$node4 $DBG $MEMOPT $EXTOPTS \
        --mysqld=--wsrep-provider=$GALERA2 \
        --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
        --mysqld=--wsrep_sst_receive_address=$RADDR2 \
        --mysqld=--wsrep_node_incoming_address=$ADDR \
        --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${LADDR2}$COMPAT$GDEBUG" \
        --mysqld=--socket=$node4/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node4-sst.err \
        --mysqld=--log-output=none \
        1st
    popd

    echo "Sleeping till SST is complete"
    sleep 100

    ver_and_row $node3/socket.sock
    ver_and_row $node4/socket.sock

    echo "Shutting down node4 after SST"
    ${MYSQL_BASEDIR1}/bin/mysqladmin  --socket=$node4/socket.sock -u root shutdown

    rw_ist $node3/socket.sock $WORKDIR/logs/sysbench_for_ist_r.txt
    sleep 10

  reset_compat $GALERA2
    pushd ${MYSQL_BASEDIR2}/mysql-test/
    echo "Restarting for IST"
    perl mysql-test-run.pl \
        --mysqld=--basedir=${MYSQL_BASEDIR2} \
        --start-dirty \
        --port-base=$RBASE2 \
        $common \
        --vardir=$node4 $DBG $MEMOPT $EXTOPTS \
        --mysqld=--wsrep-provider=$GALERA2 \
        --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
        --mysqld=--wsrep_sst_receive_address=$RADDR2 \
        --mysqld=--wsrep_node_incoming_address=$ADDR \
        --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${LADDR2}$COMPAT$GDEBUG" \
        --mysqld=--socket=$node4/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node4-ist.err \
        --mysqld=--log-output=none \
        1st
    popd

    sleep 100

    ver_and_row $node3/socket.sock
    ver_and_row $node4/socket.sock

    get_script

    $MYSQL_BASEDIR1/bin/mysql -S $node3/socket.sock  -u root -e "create database testdb;" || true

    rw_full $sockets  $WORKDIR/logs/sysbench_rw_run_r.txt

    if [[ $VER1 > $VER2 ]];then
        node_for_upgrade=$VER2
        nodeu=$node4
        pbase=$RBASE2
        baseu=$MYSQL_BASEDIR1
        ugalera="${baseu}/lib/libgalera_smm.so"
        listu=$LADDR2
        recvu=$RADDR2
    else
        node_for_upgrade=$VER1
        nodeu=$node2
        pbase=$RBASE1
        baseu=$MYSQL_BASEDIR2
        ugalera="${baseu}/lib/libgalera_smm.so"
        listu=$LADDR1
        recvu=$RADDR1
    fi
    if [[ ! -e $ugalera ]];then
        ugalera="${baseu}/lib/galera3/libgalera_smm.so"
    fi

    echo "Shutting down node4 for upgrade"
    $baseu/bin/mysqladmin  --socket=$nodeu/socket.sock -u root shutdown

    pushd ${baseu}/mysql-test/
    perl mysql-test-run.pl \
        --mysqld=--basedir=${baseu} \
        --port-base=$pbase \
        $u_common \
        --vardir=$nodeu $DBG $MEMOPT $EXTOPTS \
        --mysqld=--socket=$nodeu/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node4-upgrade.err \
        --mysqld=--log-output=none \
        1st
    popd

    $MYSQL_BASEDIR1/bin/mysql_upgrade -S $node4/socket.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade_r.log


    echo "Shutting down node4 after upgrade"
    $MYSQL_BASEDIR1/bin/mysqladmin  --socket=$node4/socket.sock -u root shutdown

    echo "Starting node4 after upgrade"

  reset_compat $ugalera
  pushd ${baseu}/mysql-test/
  perl mysql-test-run.pl \
    --mysqld=--basedir=${baseu} \
    --port-base=$pbase \
    $common \
    --vardir=$nodeu $DBG $MEMOPT $EXTOPTS \
    --mysqld=--wsrep-provider=$ugalera \
    --mysqld=--wsrep_cluster_address=gcomm://$LADDR1,$LADDR2 \
    --mysqld=--wsrep_sst_receive_address=$recvu \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://${listu}$COMPAT$GDEBUG" \
    --mysqld=--socket=$nodeu/socket.sock \
    --mysqld=--log-error=$WORKDIR/logs/node4-postupgrade.err \
    --mysqld=--log-output=none \
    1st
  popd


    get_script


    rw_full $sockets  $WORKDIR/logs/sysbench_rw_run_r-2.txt
    sleep 100

    ver_and_row $node3/socket.sock
    ver_and_row $node4/socket.sock
    $MYSQL_BASEDIR1/bin/mysql -S $node3/socket.sock  -u root -e "drop database testdb;" || true
    $MYSQL_BASEDIR1/bin/mysql -S $node3/socket.sock  -u root -e "drop database test;"

    echo "Shutting down node4 after IST"
    $MYSQL_BASEDIR2/bin/mysqladmin  --socket=$node4/socket.sock -u root shutdown

    sleep 10

    echo "Shutting down node3 after IST"
    $MYSQL_BASEDIR2/bin/mysqladmin  --socket=$node3/socket.sock -u root shutdown

  exit $EXTSTATUS
