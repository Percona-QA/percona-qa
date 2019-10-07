#!/bin/bash
# PXC performance benchmark scripts
# Sysbench suite will run CPUBOUND and IOBOUND performance tests
# **********************************************************************************************
# generic variables
# **********************************************************************************************
export ADDR="127.0.0.1"
export RPORT=$(( RANDOM%21 + 10 ))
export RBASE="$(( RPORT*1000 ))"
export SUSER=root
export SPASS=
export BIG_DIR=${WORKSPACE}
export SCRIPT_DIR=$(cd $(dirname $0) && pwd)
export PXC_START_TIMEOUT=300
export MYSQL_DATABASE=test
export MYSQL_NAME=PXC
export NODES=3

# Check if workdir was set by Jenkins, otherwise this is presumably a local run
if [ -z ${BIG_DIR} ]; then
  export BIG_DIR=${PWD}
fi

# make sure we have passed basedir parameter for this benchmark run
if [ -z $2 ]; then
  echo "No valid parameter passed.  Need relative workdir (1st option) and relative basedir (2nd option) settings. Retry."
  echo "Usage example:"
  echo "$./pxc.performance-test.sh 10 Percona-XtraDB-Cluster-5.7.14-rel8-26.17.1.Linux.x86_64"
  echo "This would lead to $BIG_DIR/100 being created, in which testing takes place and"
  echo "$BIG_DIR/$1/Percona-Server-5.5.28-rel29.3-435.Linux.x86_64 would be used to test."
  exit 1
else
  mkdir -p $BIG_DIR/$1
  cp -r $BIG_DIR/$2 $BIG_DIR/$1
  export BUILD_NUMBER=$1
  export DB_DIR=$BIG_DIR/$1/$2
  mkdir -p $BIG_DIR/$1/logs
  export LOGS=$BIG_DIR/$1/logs
fi

export MYSQL_SOCKET=${DB_DIR}/node1/socket.sock
export MYSQL_VERSION=`$DB_DIR/bin/mysqld --version | awk '{ print $3}'`

archives() {
  tar czf ${BIG_DIR}/results-${BUILD_NUMBER}.tar.gz ${LOGS} ${DB_DIR}/node*/*.err true
}

trap archives EXIT KILL

if [ ! -d ${BIG_DIR}/backups ]; then
  mkdir -p ${BIG_DIR}/backups
  SCP_TARGET=${BIG_DIR}/backups
else
  SCP_TARGET=${BIG_DIR}/backups
fi

#Check if MYEXTRA was set by Jenkins, otherwise this is presumably a local run
if [ ! -z ${MYEXTRA} ]; then
  export MYEXTRA=${MYEXTRA}
else
  export MYEXTRA=""
fi

if [ -z $WORKSPACE ]; then
  echo "Assuming this is a local (i.e. non-Jenkins initiated) run."
  export WORKSPACE=$BIG_DIR/backups
fi

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  SDURATION="$3"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$NUM_ROWS --oltp_tables_count=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --num-threads=$NUM_TABLES --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --rand-init=on --oltp-table-size=$NUM_ROWS --oltp_tables_count=$NUM_TABLES --max-time=$SDURATION --report-interval=10 --max-requests=1870000000 --mysql-db=$DB --mysql-user=$SUSER  --num-threads=$num_threads --db-driver=mysql --oltp-non-index-updates=1 --db-ps-mode=disable"
    elif [ "$TEST_TYPE" == "oltp_read" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --rand-init=on --oltp-table-size=$NUM_ROWS --oltp-read-only --oltp_tables_count=$NUM_TABLES --max-time=$SDURATION --report-interval=10 --max-requests=1870000000 --mysql-db=$DB  --mysql-user=$SUSER --num-threads=$num_threads --db-driver=mysql --db-ps-mode=disable"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --threads=$NUM_TABLES --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --threads=$num_threads --time=$SDURATION --report-interval=10 --events=1870000000 --db-driver=mysql --non_index_updates=1 --db-ps-mode=disable"
    elif [ "$TEST_TYPE" == "oltp_read" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_only.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER --threads=$num_threads --time=$SDURATION --report-interval=10 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

# Default my.cnf creation
# Creating default my.cnf file
rm -rf $BIG_DIR/my.cnf
if [ ! -f $BIG_DIR/my.cnf ]; then
  echo "[mysqld]" > my.cnf
  echo "basedir=${DB_DIR}" >> my.cnf
  echo "binlog_format=ROW" >> my.cnf
  echo "innodb_autoinc_lock_mode=2" >> my.cnf
  echo "sync_binlog=0" >> my.cnf
  echo "wsrep-provider=${DB_DIR}/lib/libgalera_smm.so" >> my.cnf
  echo "wsrep_node_incoming_address=$ADDR" >> my.cnf
  echo "wsrep_sst_auth=$SUSER:$SPASS" >> my.cnf
  echo "wsrep_node_address=$ADDR" >> my.cnf
  echo "core-file" >> my.cnf
  echo "max-connections=1048" >> my.cnf
fi

# Setting seeddb creation configuration
if [ "$(${DB_DIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${DB_DIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${DB_DIR}"
  WS_DATADIR="${BIG_DIR}/57_sysbench_data_template"
elif [ "$(${DB_DIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${DB_DIR}/scripts/mysql_install_db --no-defaults --basedir=${DB_DIR}"
  WS_DATADIR="${BIG_DIR}/56_sysbench_data_template"
fi

function start_multi_node(){
  ps -ef | grep 'socket.sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  MYEXTRA="--innodb-buffer-pool-size=$INNODB_CACHE"
  run_mid=0
  if [ "$1" == "startup" ];then
    run_mid=1
  fi
  for i in `seq 1 $NODES`;do
    RBASE1="$(( RBASE + ( 100 * $i ) ))"
    LADDR1="$ADDR:$(( RBASE1 + 8 ))"
    WSREP_CLUSTER="${WSREP_CLUSTER}gcomm://$LADDR1,"
    if [ $run_mid -eq 1 ]; then
      node="${WS_DATADIR}/node${DATASIZE}_$i"
      if [ "$(${DB_DIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
        mkdir -p $node
        ${MID} --datadir=$node  > $LOGS/startup_node$i.err 2>&1
      else
        if [ ! -d $node ]; then
          ${MID} --datadir=$node  > $LOGS/startup_node$i.err 2>&1
        fi
      fi
    else
      node="${DB_DIR}/node$i"
    fi
    if [ $i -eq 1 ]; then
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=gcomm:// "
    else
      WSREP_CLUSTER_ADD="--wsrep_cluster_address=$WSREP_CLUSTER"
    fi

    ${DB_DIR}/bin/mysqld --defaults-file=${BIG_DIR}/my.cnf \
      --datadir=$node $WSREP_CLUSTER_ADD $MYEXTRA \
      --wsrep_provider_options=gmcast.listen_addr=tcp://$LADDR1 \
      --log-error=$node/node$i.err  \
      --socket=$node/socket.sock --port=$RBASE1 > $node/node$i.err 2>&1 &

    for X in $(seq 0 ${PXC_START_TIMEOUT}); do
      sleep 1
      if ${DB_DIR}/bin/mysqladmin -uroot -S$node/socket.sock ping > /dev/null 2>&1; then
        echo "Started PXC node$i. Socket : $node/socket.sock"
        break
      fi
    done
  done
  if [ $run_mid -eq 1 ]; then
    ${DB_DIR}/bin/mysql -uroot -S${WS_DATADIR}/node${DATASIZE}_1/socket.sock -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE" 2>&1
    sysbench_run load_data $MYSQL_DATABASE
    sysbench $SYSBENCH_OPTIONS --mysql-socket=${WS_DATADIR}/node${DATASIZE}_1/socket.sock prepare > $LOGS/sysbench_prepare.log 2>&1
    for i in `seq $NODES -1 1`;do
      timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=${WS_DATADIR}/node${DATASIZE}_${i}/socket.sock shutdown > /dev/null 2>&1
    done
  fi
}

function check_memory(){
  CHECK_PID=`ps -ef | grep node1 | grep -v grep | awk '{ print $2}'`
  WAIT_TIME_SECONDS=10
  while [ ${RUN_TIME_SECONDS} -gt 0 ]; do
    DATE=`date +"%Y%m%d%H%M%S"`
    CURRENT_INFO=`ps -o rss,vsz,pcpu ${CHECK_PID} | tail -n 1`
    echo "${DATE} ${CURRENT_INFO}" >> ${LOG_NAME_MEMORY}
    RUN_TIME_SECONDS=$(($RUN_TIME_SECONDS - $WAIT_TIME_SECONDS))
    sleep ${WAIT_TIME_SECONDS}
  done
}


function start_pxc(){
  for i in `seq 1 $NODES`;do
    timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=${WS_DATADIR}/node${i}/socket.sock shutdown > /dev/null 2>&1
  done
  ps -ef | grep 'socket.sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi

  if [ -d ${WS_DATADIR}/node${DATASIZE}_1 ]; then
    for i in `seq 1 $NODES`;do
     cp -r ${WS_DATADIR}/node${DATASIZE}_${i} ${DB_DIR}/node${i}
    done
    start_multi_node
  else
    mkdir ${WS_DATADIR} > /dev/null 2>&1
    start_multi_node startup
    for i in `seq 1 $NODES`;do
     cp -r ${WS_DATADIR}/node${DATASIZE}_${i} ${DB_DIR}/node${i}
    done
    start_multi_node
  fi
}

function sysbench_rw_run(){
  MEM_PID=()
  if [ ${WARMUP} == "Y" ]; then
    #warmup the cache, 64 threads for 10 minutes, don't bother logging
    # *** REMEMBER *** warmmup is READ ONLY!
    num_threads=64
    WARMUP_TIME_SECONDS=600
    sysbench_run oltp_read $MYSQL_DATABASE $WARMUP_TIME_SECONDS
    sysbench $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=${DB_DIR}/node1/socket.sock --percentile=99 run > $LOGS/sysbench_warmup.log 2>&1
    sleep 60
  fi
  echo "Storing Sysbench results in ${WORKSPACE}"
  for num_threads in ${threadCountList}; do
    LOG_NAME=${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}-$NUM_ROWS-$num_threads.txt
    LOG_NAME_MEMORY=${LOG_NAME}.memory
    LOG_NAME_IOSTAT=${LOG_NAME}.iostat
    LOG_NAME_DSTAT=${LOG_NAME}.dstat
    LOG_NAME_DSTAT_CSV=${LOG_NAME}.dstat.csv

    if [ ${BENCHMARK_LOGGING} == "Y" ]; then
        # verbose logging
        echo "*** verbose benchmark logging enabled ***"
        check_memory &
        MEM_PID+=("$!")
        iostat -dxm $IOSTAT_INTERVAL $IOSTAT_ROUNDS  > $LOG_NAME_IOSTAT &
        dstat -t -v --nocolor --output $LOG_NAME_DSTAT_CSV $DSTAT_INTERVAL $DSTAT_ROUNDS > $LOG_NAME_DSTAT &
    fi
    sysbench_run oltp $MYSQL_DATABASE $RUN_TIME_SECONDS
    sysbench $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=${DB_DIR}/node1/socket.sock --percentile=99 run | tee $LOG_NAME
    sleep 6
    result_set+=(`grep  "queries:" $LOG_NAME | cut -d'(' -f2 | awk '{print $1 ","}'`)
  done

  pkill -f dstat
  pkill -f iostat
  kill -9 ${MEM_PID[@]}
  for i in `seq $NODES -1 1`;do
    timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=${WS_DATADIR}/node${i}/socket.sock shutdown > /dev/null 2>&1
  done
  ps -ef | grep 'socket.sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  for i in {0..7}; do if [ -z ${result_set[i]} ]; then  result_set[i]='0,' ; fi; done
  echo "[ '${BUILD_NUMBER}', ${result_set[*]} ]," >> ${LOGS}/sysbench_${BENCH_ID}_perf_result_set.txt
  unset result_set
  tarFileName="sysbench_${BENCH_ID}_perf_result_set_${DATE}.tar.gz"
  tar czvf ${tarFileName} ${MYSQL_NAME}* ${DB_DIR}/node*/*.err
  mkdir -p ${SCP_TARGET}/${BUILD_NUMBER}/${BENCH_SUITE}/${BENCH_ID}
  BACKUP_FILES="${SCP_TARGET}/${BUILD_NUMBER}/${BENCH_SUITE}/${BENCH_ID}"
  cp ${tarFileName} ${BACKUP_FILES}
  rm -rf ${MYSQL_NAME}*
  rm -rf ${DB_DIR}/node*

}

iibench_insert_run(){
  LOG_NAME=${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}.txt
  LOG_NAME_MEMORY=${LOG_NAME}.memory
  LOG_NAME_IOSTAT=${LOG_NAME}.iostat
  LOG_NAME_DSTAT=${LOG_NAME}.dstat
  LOG_NAME_DSTAT_CSV=${LOG_NAME}.dstat.csv
  if [ ${BENCHMARK_LOGGING} == "Y" ]; then
    # verbose logging
    echo "*** verbose benchmark logging enabled ***"
    check_memory &
    MEM_PID+=("$!")
    iostat -dxm $IOSTAT_INTERVAL $IOSTAT_ROUNDS  > $LOG_NAME_IOSTAT &
    dstat -t -v --nocolor --output $LOG_NAME_DSTAT_CSV $DSTAT_INTERVAL $DSTAT_ROUNDS > $LOG_NAME_DSTAT &
  fi
  python iibench.py ${CREATE_TABLE_STRING} --db_user=$SUSER --db_password=$SPASS --db_socket=${DB_DIR}/node1/socket.sock  --db_name=${MYSQL_DATABASE} --max_rows=${MAX_ROWS} --max_table_rows=${MAX_TABLE_ROWS} --rows_per_report=${ROWS_PER_REPORT} --engine=INNODB ${IIBENCH_QUERY_PARM} --unique_checks=${UNIQUE_CHECKS} --run_minutes=${RUN_MINUTES} --tokudb_commit_sync=${COMMIT_SYNC} --max_ips=${MAX_IPS} --num_secondary_indexes=${NUM_SECONDARY_INDEXES} | tee $LOG_NAME

}


# **********************************************************************************************
# sysbench
# **********************************************************************************************
export threadCountList="0001 0004 0016 0064 0128 0256 0512 1024"
export WARMUP=Y
export BENCHMARK_LOGGING=Y
export RUN_TIME_SECONDS=300
export REPORT_INTERVAL=10
export IOSTAT_INTERVAL=10
export IOSTAT_ROUNDS=$[RUN_TIME_SECONDS/IOSTAT_INTERVAL+1]
export DSTAT_INTERVAL=10
export DSTAT_ROUNDS=$[RUN_TIME_SECONDS/DSTAT_INTERVAL+1]

# CPU bound performance run
export DATASIZE=5M
export BENCH_SUITE=sysbench
export INNODB_CACHE=25G
export NUM_TABLES=16
export RAND_TYPE=uniform
export BENCH_ID=innodb-5mm-${RAND_TYPE}-cpubound
export NUM_ROWS=5000000
export BENCHMARK_NUMBER=001

start_pxc
sysbench_rw_run

# IO bound performance run
export DATASIZE=5M
export INNODB_CACHE=15G
export NUM_TABLES=16
export RAND_TYPE=uniform
export BENCH_ID=innodb-5mm-${RAND_TYPE}-iobound
export NUM_ROWS=5000000
export BENCHMARK_NUMBER=002


start_pxc
sysbench_rw_run

# CPU bound performance run
export DATASIZE=1M
export INNODB_CACHE=5G
export NUM_ROWS=1000000
export RAND_TYPE=uniform
export BENCH_ID=innodb-1mm-${RAND_TYPE}-cpubound
export BENCHMARK_NUMBER=003

start_pxc
sysbench_rw_run

# IO bound performance run
export DATASIZE=1M
export INNODB_CACHE=1G
export NUM_ROWS=1000000
export RAND_TYPE=uniform
export BENCH_ID=innodb-1mm-${RAND_TYPE}-iobound
export BENCHMARK_NUMBER=004

start_pxc
sysbench_rw_run

export CREATE_TABLE_STRING="--setup"
export BENCH_SUITE=iibench
export BENCH_ID=innodb-10m-$BENCH_SUITE
export INNODB_CACHE=25G
export MYSQL_DATABASE=test
export MAX_ROWS=10000000
export MAX_TABLE_ROWS=10000000
export ROWS_PER_REPORT=100000
export IIBENCH_QUERY_PARM="--insert_only"
export UNIQUE_CHECKS=1
export RUN_MINUTES=60
export COMMIT_SYNC=0
export MAX_IPS=-1
export NUM_SECONDARY_INDEXES=3

#Generate graph
VERSION_INFO=`$DB_DIR/bin/mysqld --version | cut -d' ' -f2-`
UPTIME_HOUR=`uptime -p`
SYSTEM_LOAD=`uptime | sed 's|  | |g' | sed -e 's|.*user*.,|System|'`
MEM=`free -g | grep "Mem:" | awk '{print "Total:"$2"GB  Used:"$3"GB  Free:"$4"GB" }'`
if [ ! -f $LOGS/hw.info ];then
  RELEASE=`cat /etc/redhat-release`
  KERNEL=`uname -r`
  echo "HW info | $RELEASE $KERNEL"  > $LOGS/hw.info
fi
echo "Build #$BUILD_NUMBER | `date +'%d-%m-%Y | %H:%M'` | $VERSION_INFO | $UPTIME_HOUR | $SYSTEM_LOAD | Memory: $MEM " >> $LOGS/build_info.log
$SCRIPT_DIR/multibench_html_gen.sh $LOGS

#start_pxc
#iibench_insert_run

exit 0
