#!/bin/bash -ue

# Author: Raghavendra Prabhu

ulimit -c unlimited
export MTR_MAX_SAVE_CORE=5

set +e
echo "Killing existing mysqld"
pgrep -f mysqld

pkill -f mysqld
sleep 10
pgrep mysqld || pkill -9 -f mysqld

sleep 5



WORKDIR=$1
ROOT_FS=$WORKDIR
sst_method="rsync"

cd $WORKDIR


count=$(ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then
    for dirs in `ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | tail -n +2`;do
        rm -rf $dirs
    done
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.6*' -exec rm -rf {} \+



count=$(ls -1ct Percona-XtraDB-Cluster-5.5*.tar.gz | wc -l)

if [[ $count -gt 1 ]];then
    for dirs in `ls -1ct Percona-XtraDB-Cluster-5.5*.tar.gz | tail -n +2`;do
        rm -rf $dirs
    done
fi

find . -maxdepth 1 -type d -name 'Percona-XtraDB-Cluster-5.5*' -exec rm -rf {} \+


echo "Removing older directories"
find . -maxdepth 1 -type d -mtime +10 -exec rm -rf {} \+

echo "Removing their symlinks"
find . -maxdepth 1 -type l -mtime +10 -delete

TAR=`ls -1ct Percona-XtraDB-Cluster-5.5*.tar.gz | head -n1`
BASE1="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR

TAR=`ls -1ct Percona-XtraDB-Cluster-5.6*.tar.gz | head -n1`
BASE2="$(tar tf $TAR | head -1 | tr -d '/')"

tar -xf $TAR


LPATH=${SPATH:-/usr/share/doc/sysbench/tests/db}

# Parameter of parameterized build
if [[ -n $SDURATION ]];then
    export SYSBENCH_DURATION=$SDURATION
else
    export SYSBENCH_DURATION=300
fi

# User settings
SENDMAIL="/usr/sbin/sendmail"


WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

MYSQL_BASEDIR1="${ROOT_FS}/$BASE1"
MYSQL_BASEDIR2="${ROOT_FS}/$BASE2"
export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR

SDIR="$LPATH"
SRESULTS="$WORKDIR/sresults"

mkdir -p $SRESULTS

echo "Workdir: $WORKDIR"
echo "Basedirs: $MYSQL_BASEDIR1 $MYSQL_BASEDIR2"

if [[ $THREEONLY -eq 1 ]];then
    GALERA2="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
    GALERA3="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
else
    GALERA2="${MYSQL_BASEDIR1}/lib/galera2/libgalera_smm.so"
    GALERA3="${MYSQL_BASEDIR2}/lib/libgalera_smm.so"
fi


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


trap "tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs" EXIT KILL

if [[ -n ${EXTERNALS:-} ]];then
    EXTOPTS="$EXTERNALS"
else
    EXTOPTS=""
fi


#if [[ $BUILD_SOURCE == 'debug' ]];then
    #EXTOPTS+=" --mysqld=--skip-performance-schema "
#fi

if [[ $DEBUG -eq 1 ]];then
    DBG="--mysqld=--wsrep-debug=1"
else
    DBG=""
fi

  echo "Starting 5.5 node"

  pushd ${MYSQL_BASEDIR1}/mysql-test/

  set +e
  perl mysql-test-run.pl \
    --mysqld=--basedir=${MYSQL_BASEDIR1} \
    --start-and-exit \
    --port-base=$RBASE1 \
    --nowarnings \
    --vardir=$node1 $DBG $MEMOPT $EXTOPTS \
    --nodefault-myisam \
    --mysqld=--innodb_file_per_table  \
    --mysqld=--binlog-format=ROW \
    --mysqld=--wsrep-slave-threads=8 \
    --mysqld=--innodb_autoinc_lock_mode=2 \
    --mysqld=--wsrep-provider=$GALERA2 \
    --mysqld=--wsrep_cluster_address=gcomm:// \
    --mysqld=--wsrep_sst_receive_address=$RADDR1 \
    --mysqld=--wsrep_node_incoming_address=$ADDR \
    --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR1" \
    --mysqld=--wsrep_sst_method=$sst_method \
    --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
    --mysqld=--wsrep_node_address=$ADDR \
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
    --mysqld=--socket=$node1/socket.sock \
    --mysqld=--log-error=$WORKDIR/logs/node1.err \
    --mysqld=--log-output=none \
    1st
  set -e
  popd



    # Sysbench Runs
    ## Prepare/setup
    echo "Sysbench Run: Prepare stage"

    sysbench --test=$SDIR/parallel_prepare.lua --report-interval=10  --oltp-auto-inc=$AUTOINC --mysql-engine-trx=yes --mysql-table-engine=innodb \
        --oltp-table-size=$TSIZE --oltp_tables_count=100 --mysql-db=test --mysql-user=root \
        --db-driver=mysql --mysql-socket=$node1/socket.sock prepare 2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

    if [[ ${PIPESTATUS[0]} -ne 0 ]];then
        echo "Sysbench prepare failed"
        exit 1
    fi

    $MYSQL_BASEDIR1/bin/mysql  -S $node1/socket.sock -u root -e "create database testdb;" || true


    pushd ${MYSQL_BASEDIR1}/mysql-test/
    export MYSQLD_BOOTSTRAP_CMD=
    set +e
    perl mysql-test-run.pl \
        --mysqld=--basedir=${MYSQL_BASEDIR1} \
        --start-and-exit \
        --port-base=$RBASE2 \
        --nowarnings \
        --nodefault-myisam \
        --vardir=$node2 $DBG $MEMOPT $EXTOPTS \
        --mysqld=--innodb_file_per_table  \
        --mysqld=--binlog-format=ROW \
        --mysqld=--wsrep-slave-threads=8 \
        --mysqld=--innodb_autoinc_lock_mode=2 \
        --mysqld=--wsrep-provider=$GALERA2 \
        --mysqld=--wsrep_cluster_address=gcomm://$LADDR1 \
        --mysqld=--wsrep_sst_receive_address=$RADDR2 \
        --mysqld=--wsrep_node_incoming_address=$ADDR \
        --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2" \
        --mysqld=--wsrep_sst_method=$sst_method \
        --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
        --mysqld=--wsrep_node_address=$ADDR \
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
        --mysqld=--socket=$node2/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node2-pre.err \
        --mysqld=--log-output=none \
        1st
    set -e

    echo "Sleeping till SST is complete"
    sleep 10

    echo "Version of second node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "show global variables like 'version';"

    echo "Shutting down node2 after SST"
    ${MYSQL_BASEDIR1}/bin/mysqladmin  --socket=$node2/socket.sock -u root shutdown

    if [[ $? -ne 0 ]];then
        echo "Shutdown failed for node2"
        exit 1
    fi

    popd

    sleep 10


    pushd ${MYSQL_BASEDIR2}/mysql-test/
    export MYSQLD_BOOTSTRAP_CMD=

    echo "Running for upgrade"

    perl mysql-test-run.pl \
        --mysqld=--basedir=${MYSQL_BASEDIR2} \
        --start-and-exit \
        --start-dirty \
        --port-base=$RBASE2 \
        --nowarnings \
        --nodefault-myisam \
        --vardir=$node2 $DBG $MEMOPT $EXTOPTS \
        --mysqld=--skip-grant-tables \
        --mysqld=--innodb_file_per_table  \
        --mysqld=--binlog-format=ROW \
        --mysqld=--innodb_autoinc_lock_mode=2 \
        --mysqld=--wsrep-provider='none' \
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
        --mysqld=--socket=$node2/socket.sock \
        --mysqld=--log-error=$WORKDIR/logs/node2-upgrade.err \
        --mysqld=--log-output=none \
        1st

    $MYSQL_BASEDIR2/bin/mysql_upgrade -S $node2/socket.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

    if [[ $? -ne 0 ]];then
        echo "mysql upgrade failed"
        exit 1
    fi

    echo "Version of second node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "show global variables like 'version';"


    echo "Shutting down node2 after upgrade"
    $MYSQL_BASEDIR2/bin/mysqladmin  --socket=$node2/socket.sock -u root shutdown


    if [[ $? -ne 0 ]];then
        echo "Shutdown failed for node2"
        exit 1
    fi

    sleep 10



    if [[ $THREEONLY -eq 0 ]];then
    echo "Starting again with compat options"
        perl mysql-test-run.pl \
            --mysqld=--basedir=${MYSQL_BASEDIR2} \
            --start-and-exit \
            --start-dirty \
            --port-base=$RBASE2 \
            --nowarnings \
            --nodefault-myisam \
            --vardir=$node2 $DBG $MEMOPT $EXTOPTS \
            --mysqld=--innodb_file_per_table  \
            --mysqld=--binlog-format=ROW \
            --mysqld=--wsrep-slave-threads=8 \
            --mysqld=--innodb_autoinc_lock_mode=2 \
            --mysqld=--wsrep-provider=$GALERA3 \
            --mysqld=--wsrep_cluster_address=gcomm://$LADDR1 \
            --mysqld=--wsrep_sst_receive_address=$RADDR2 \
            --mysqld=--wsrep_node_incoming_address=$ADDR \
            --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2; socket.checksum=1" \
            --mysqld=--wsrep_sst_method=$sst_method \
            --mysqld=--log_bin_use_v1_row_events=1 \
            --mysqld=--gtid_mode=0 \
            --mysqld=--binlog_checksum=NONE \
            --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
            --mysqld=--wsrep_node_address=$ADDR \
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
            --mysqld=--socket=$node2/socket.sock \
            --mysqld=--log-error=$WORKDIR/logs/node2-post.err \
            --mysqld=--log-output=none \
            1st
    else
    echo "Starting node again without compat"
        perl mysql-test-run.pl \
            --mysqld=--basedir=${MYSQL_BASEDIR2} \
            --start-and-exit \
            --start-dirty \
            --port-base=$RBASE2 \
            --nowarnings \
            --nodefault-myisam \
            --vardir=$node2 $DBG $MEMOPT $EXTOPTS \
            --mysqld=--innodb_file_per_table  \
            --mysqld=--binlog-format=ROW \
            --mysqld=--wsrep-slave-threads=8 \
            --mysqld=--innodb_autoinc_lock_mode=2 \
            --mysqld=--wsrep-provider=$GALERA3 \
            --mysqld=--wsrep_cluster_address=gcomm://$LADDR1 \
            --mysqld=--wsrep_sst_receive_address=$RADDR2 \
            --mysqld=--wsrep_node_incoming_address=$ADDR \
            --mysqld=--wsrep_provider_options="gmcast.listen_addr=tcp://$LADDR2" \
            --mysqld=--wsrep_sst_method=$sst_method \
            --mysqld=--log_bin_use_v1_row_events=1 \
            --mysqld=--gtid_mode=0 \
            --mysqld=--binlog_checksum=NONE \
            --mysqld=--wsrep_sst_auth=$SUSER:$SPASS \
            --mysqld=--wsrep_node_address=$ADDR \
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
            --mysqld=--socket=$node2/socket.sock \
            --mysqld=--log-error=$WORKDIR/logs/node2-post.err \
            --mysqld=--log-output=none \
            1st
    fi

    popd

    echo "Version of second node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "show global variables like 'version';"

  echo "Sleeping for 10s"
  sleep 10


       STABLE="test.sbtest1"

    echo "Before RW testing"
    echo "Rows on node1"
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "select count(*) from $STABLE;"
    echo "Rows on node2"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "select count(*) from $STABLE;"


    echo "Version of first node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "show global variables like 'version';"
    echo "Version of second node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "show global variables like 'version';"


    if [[ ! -e $SDIR/${STEST}.lua ]];then
        pushd /tmp

        rm $STEST.lua || true
        wget -O $STEST.lua  https://github.com/Percona-QA/sysbench/tree/0.5/sysbench/tests/db/${STEST}.lua
        SDIR=/tmp/
        popd
    fi

   set -x


    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "create database testdb;" || true

    if [[ $DIR -eq 1 ]];then
        sockets="$node1/socket.sock,$node2/socket.sock"
    elif [[ $DIR -eq 2 ]];then
        sockets="$node2/socket.sock"
    elif [[ $DIR -eq 3 ]];then
        sockets="$node1/socket.sock"
    fi



        ## OLTP RW Run
        echo "Sysbench Run: OLTP RW testing"
            sysbench --mysql-table-engine=innodb --num-threads=$NUMT --report-interval=10 --oltp-auto-inc=$AUTOINC --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
                --test=$SDIR/$STEST.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=100 --mysql-db=test \
                --mysql-user=root --db-driver=mysql --mysql-socket=$sockets \
                run 2>&1 | tee $WORKDIR/logs/sysbench_rw_run.txt



    if [[ ${PIPESTATUS[0]} -ne 0 ]];then
        echo "Sysbench run failed"
        EXTSTATUS=1
    fi

  set +x


    echo "Version of first node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "show global variables like 'version';"
    echo "Version of second node:"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "show global variables like 'version';"

    echo "Rows on node1"
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "select count(*) from $STABLE;"
    echo "Rows on node2"
    $MYSQL_BASEDIR1/bin/mysql -S $node2/socket.sock  -u root -e "select count(*) from $STABLE;"

    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "drop database testdb;" || true
    $MYSQL_BASEDIR1/bin/mysql -S $node1/socket.sock  -u root -e "drop database test;"

  exit $EXTSTATUS



