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
export BIG_DIR=${PWD}
export SCRIPT_DIR=$(cd $(dirname $0) && pwd)
export PXC_START_TIMEOUT=300
export MYSQL_DATABASE=test
export MYSQL_NAME=PXC
export SYSBENCH_DIR=/usr/share/doc/sysbench
export NODES=1

# make sure we have passed basedir parameter for this benchmark run
if [ -z $2 ]; then
  echo "No valid parameter passed.  Need relative workdir (1st option) and relative basedir (2nd option) settings. Retry."
  echo "Usage example:"
  echo "$./ps.multibench 10 Percona-Server-5.5.28-rel29.3-435.Linux.x86_64"
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

# Check if workdir was set by Jenkins, otherwise this is presumably a local run
if [ ! -z ${WORKDIR} ]; then
  export BIG_DIR=${WORKDIR}
fi

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

export WORKSPACE_LOC=$BIG_DIR/backups


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
    /usr/bin/sysbench --test=${SYSBENCH_DIR}/tests/db/parallel_prepare.lua --num-threads=${NUM_TABLES} --oltp-tables-count=${NUM_TABLES}  --oltp-table-size=${NUM_ROWS} --mysql-db=test --mysql-user=root    --db-driver=mysql --mysql-socket=${WS_DATADIR}/node${DATASIZE}_1/socket.sock run > $LOGS/sysbench_prepare.log 2>&1
    for i in `seq 1 $NODES`;do
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
    sysbench --test=${SYSBENCH_DIR}/tests/db/oltp.lua --oltp_tables_count=$NUM_TABLES --oltp-table-size=$NUM_ROWS --rand-init=on --num-threads=$num_threads --oltp-read-only=on --report-interval=$REPORT_INTERVAL --rand-type=$RAND_TYPE --mysql-socket=${DB_DIR}/node1/socket.sock --mysql-table-engine=InnoDB --max-time=$WARMUP_TIME_SECONDS --mysql-user=$SUSER --mysql-password=$SPASS --mysql-db=${MYSQL_DATABASE} --max-requests=0 --percentile=99 run > $LOGS/sysbench_warmup.log 2>&1
    sleep 60
  fi

  for num_threads in ${threadCountList}; do
    LOG_NAME=${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}-$LOG_BENCHMARK_NAME-$NUM_ROWS-$num_threads.txt
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

    sysbench --test=${SYSBENCH_DIR}/tests/db/oltp.lua --oltp-non-index-updates=1 --oltp_tables_count=$NUM_TABLES --oltp-table-size=$NUM_ROWS --rand-init=on --num-threads=$num_threads  --report-interval=$REPORT_INTERVAL --rand-type=$RAND_TYPE --mysql-socket=${DB_DIR}/node1/socket.sock --mysql-table-engine=InnoDB --max-time=$RUN_TIME_SECONDS --mysql-user=$SUSER --mysql-password=$SPASS --mysql-db=${MYSQL_DATABASE} --max-requests=0 --percentile=99 run | tee $LOG_NAME
    sleep 6
    AVG_TRANS=`grep "transactions:" $LOG_NAME | awk '{print $3}' | sed 's/(//'`
    echo "$num_threads : $AVG_TRANS" >> ${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}-$LOG_BENCHMARK_NAME-$NUM_ROWS.summary
  done

  pkill -f dstat
  pkill -f iostat
  kill -9 ${MEM_PID[@]}
  for i in `seq 1 $NODES`;do
    timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=${WS_DATADIR}/node${i}/socket.sock shutdown > /dev/null 2>&1
  done
  ps -ef | grep 'socket.sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  tarFileName="sysbench_${BENCH_ID}_perf_result_set_${DATE}.tar.gz"
  tar czvf ${tarFileName} ${MYSQL_NAME}* ${DB_DIR}/node*/*.err
  mkdir -p ${SCP_TARGET}/${BUILD_NUMBER}/${BENCH_SUITE}/${BENCH_ID}
  BACKUP_FILES="${SCP_TARGET}/${BUILD_NUMBER}/${BENCH_SUITE}/${BENCH_ID}"
  cp ${tarFileName} ${BACKUP_FILES}
  rm -rf ${MYSQL_NAME}* 
  rm -rf ${DB_DIR}/node*
  
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
export BENCH_ID=innodb.5mm.${RAND_TYPE}.cpubound
export NUM_ROWS=5000000
export BENCHMARK_NUMBER=001

start_pxc
sysbench_rw_run

# IO bound performance run
export DATASIZE=5M
export INNODB_CACHE=15G
export NUM_TABLES=16
export RAND_TYPE=uniform
export BENCH_ID=innodb.5mm.${RAND_TYPE}.iobound
export NUM_ROWS=5000000
export BENCHMARK_NUMBER=002


start_pxc
sysbench_rw_run

# CPU bound performance run
export DATASIZE=1M
export INNODB_CACHE=5G
export NUM_ROWS=1000000
export RAND_TYPE=uniform
export BENCH_ID=innodb-1mm.${RAND_TYPE}.cpubound
export BENCHMARK_NUMBER=003

start_pxc
sysbench_rw_run

# IO bound performance run
export DATASIZE=1M
export INNODB_CACHE=1G
export NUM_ROWS=1000000
export RAND_TYPE=uniform
export BENCH_ID=innodb-1mm.${RAND_TYPE}.iobound
export BENCHMARK_NUMBER=004

start_pxc
sysbench_rw_run

