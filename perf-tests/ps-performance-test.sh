#!/bin/bash
# set -x
# PS performance benchmark scripts
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
export PS_START_TIMEOUT=100
export MYSQL_DATABASE=test
export MYSQL_NAME=PS
SYSBENCH_DIR=${SYSBENCH_DIR:-/usr/share}
MYEXTRA=${MYEXTRA:=--disable-log-bin}

# Check if workdir was set by Jenkins, otherwise this is presumably a local run
if [ -z ${BIG_DIR} ]; then
  export BIG_DIR=${PWD}
fi

function usage(){
  echo $1
  echo "Usage example:"
  echo "$./ps.performance-test.sh 100 Percona-Server-8.0.34-26-Linux.x86_64.glibc2.35 [mysql_config_file]"
  echo "This would lead to $BIG_DIR/100 being created, in which testing takes place and"
  echo "$BIG_DIR/$1/Percona-Server-8.0.34-26-Linux.x86_64.glibc2.35 would be used to test."
  exit 1
}

function create_mysql_cnf_file(){
  # Creating default my.cnf file
  if [ ! -f $CONFIG_FILE ]; then
    echo "[mysqld]" > $CONFIG_FILE
    echo "sync_binlog=0" >> $CONFIG_FILE
    echo "core-file" >> $CONFIG_FILE
    echo "max-connections=1048" >> $CONFIG_FILE
  fi
}

# make sure we have passed basedir parameter for this benchmark run
if [ -z $2 ]; then usage "ERROR: No valid parameter passed.  Need relative workdir (1st option) and relative basedir (2nd option) settings. Retry."; fi

mkdir -p $BIG_DIR/$1
cd $BIG_DIR
export BUILD_NUMBER=$1
export DB_DIR=$BIG_DIR/$1/$2
export DATA_DIR=$BIG_DIR/$1/datadir
mkdir -p $BIG_DIR/$1/logs
export LOGS=$BIG_DIR/$1/logs
if [ -z $3 ]; then
  export CONFIG_FILE=$LOGS/my.cnf
  rm -rf $CONFIG_FILE
  create_mysql_cnf_file
else
  if [ ! -f $3 ]; then usage "ERROR: Config file $3 not found."; fi
  export CONFIG_FILE=$LOGS/$(basename $3)
  cp $3 $CONFIG_FILE
fi
echo "Using $CONFIG_FILE as mysqld config file"
echo "Copying server binaries from $BIG_DIR/$2 to $BIG_DIR/$1"
cp -r $BIG_DIR/$2 $BIG_DIR/$1

export MYSQL_SOCKET=${DB_DIR}/node1/socket.sock
export MYSQL_VERSION=`$DB_DIR/bin/mysqld --version | awk '{ print $3}'`

archives() {
  tar czf ${BIG_DIR}/results-${BUILD_NUMBER}.tar.gz ${LOGS}
}

trap archives EXIT KILL

if [ ! -d ${BIG_DIR}/backups ]; then
  mkdir -p ${BIG_DIR}/backups
  SCP_TARGET=${BIG_DIR}/backups
else
  SCP_TARGET=${BIG_DIR}/backups
fi

if [ -z $WORKSPACE ]; then
  echo "Assuming this is a local (i.e. non-Jenkins initiated) run."
  export WORKSPACE=$BIG_DIR/backups
fi

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  SDURATION="$3"
  if [ "$TEST_TYPE" == "load_data" ];then
    SYSBENCH_OPTIONS="$SYSBENCH_DIR/sysbench/oltp_insert.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --threads=$NUM_TABLES --db-driver=mysql"
  elif [ "$TEST_TYPE" == "oltp" ];then
    SYSBENCH_OPTIONS="$SYSBENCH_DIR/sysbench/oltp_read_write.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --threads=$num_threads --time=$SDURATION --report-interval=10 --events=1870000000 --db-driver=mysql --non_index_updates=1 --db-ps-mode=disable"
  elif [ "$TEST_TYPE" == "oltp_read" ];then
    SYSBENCH_OPTIONS="$SYSBENCH_DIR/sysbench/oltp_read_only.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER --threads=$num_threads --time=$SDURATION --report-interval=10 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
  fi
}

# Setting seeddb creation configuration
MID="${DB_DIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${DB_DIR}"
WS_DATADIR="${BIG_DIR}/80_sysbench_data_template"

function start_ps_node(){
  ps -ef | grep 'ps_socket.sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  EXTRA_PARAMS=$MYEXTRA
  EXTRA_PARAMS+=" --innodb-buffer-pool-size=$INNODB_CACHE"
  RBASE="$(( RBASE + 100 ))"
  if [ "$1" == "startup" ];then
    node="${WS_DATADIR}/psdata_${DATASIZE}"
    if [ ! -d $node ]; then
      ${MID} --datadir=$node  > $LOGS/startup.err 2>&1
    fi
    EXTRA_PARAMS+=" --disable-log-bin"
  else
    node="${DATA_DIR}"
  fi

  MYSQLD_OPTIONS="--defaults-file=${CONFIG_FILE} --datadir=$node --basedir=${DB_DIR} $EXTRA_PARAMS --log-error=$LOGS/master.err --socket=$LOGS/ps_socket.sock --port=$RBASE"
  echo "Starting Percona Server with options $MYSQLD_OPTIONS"
  ${DB_DIR}/bin/mysqld $MYSQLD_OPTIONS > $LOGS/master.err 2>&1 &

  for X in $(seq 0 ${PS_START_TIMEOUT}); do
    sleep 1
    if ${DB_DIR}/bin/mysqladmin -uroot -S$LOGS/ps_socket.sock ping > /dev/null 2>&1; then
      echo "Started Percona Server. Socket : $LOGS/ps_socket.sock"
      break
    fi
  done

  if [ "$1" == "startup" ];then
    echo "Creating data directory in $node"
    ${DB_DIR}/bin/mysql -uroot -S$LOGS/ps_socket.sock -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE" 2>&1
    sysbench_run load_data $MYSQL_DATABASE
    sysbench $SYSBENCH_OPTIONS --mysql-socket=$LOGS/ps_socket.sock prepare > $LOGS/sysbench_prepare.log 2>&1
    timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$LOGS/ps_socket.sock shutdown > /dev/null 2>&1
  fi
}

function check_memory(){
  CHECK_PID=`ps -ef | grep ps_socket | grep -v grep | awk '{ print $2}'`
  WAIT_TIME_SECONDS=10
  while [ ${RUN_TIME_SECONDS} -gt 0 ]; do
    DATE=`date +"%Y%m%d%H%M%S"`
    CURRENT_INFO=`ps -o rss,vsz,pcpu ${CHECK_PID} | tail -n 1`
    echo "${DATE} ${CURRENT_INFO}" >> ${LOG_NAME_MEMORY}
    RUN_TIME_SECONDS=$(($RUN_TIME_SECONDS - $WAIT_TIME_SECONDS))
    sleep ${WAIT_TIME_SECONDS}
  done
}

function drop_caches(){
  echo "Dropping caches"
  sync
  sudo sh -c 'sysctl -q -w vm.drop_caches=3'
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
}

function start_ps(){
  timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$LOGS/ps_socket.sock shutdown > /dev/null 2>&1
  ps -ef | grep 'ps_socket' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  NUM_ROWS=$(numfmt --from=si $DATASIZE)

  drop_caches
  if [ ! -d ${WS_DATADIR}/psdata_${DATASIZE} ]; then
    mkdir ${WS_DATADIR} > /dev/null 2>&1
    start_ps_node startup
  fi
  echo "Copying data directory from ${WS_DATADIR}/psdata_${DATASIZE} to ${DATA_DIR}"
  rm -rf ${DATA_DIR}
  cp -r ${WS_DATADIR}/psdata_${DATASIZE} ${DATA_DIR}
  start_ps_node
}

function sysbench_rw_run(){
  MEM_PID=()
  if [ ${WARMUP} == "Y" ]; then
    #warmup the cache, 64 threads for 10 minutes, don't bother logging
    # *** REMEMBER *** warmmup is READ ONLY!
    num_threads=64
    echo "Warming up for $WARMUP_TIME_SECONDS seconds"
    sysbench_run oltp_read $MYSQL_DATABASE $WARMUP_TIME_SECONDS
    sysbench $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=$LOGS/ps_socket.sock --percentile=99 run > $LOGS/sysbench_warmup.log 2>&1
    sleep 60
  fi
  echo "Storing Sysbench results in ${WORKSPACE}"
  for num_threads in ${threadCountList}; do
    LOG_NAME=${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}-$num_threads.txt
    LOG_NAME_MEMORY=${LOG_NAME}.memory
    LOG_NAME_IOSTAT=${LOG_NAME}.iostat
    LOG_NAME_DSTAT=${LOG_NAME}.dstat
    LOG_NAME_DSTAT_CSV=${LOG_NAME}.dstat.csv
    LOG_NAME_INXI=${LOG_NAME}.inxi

    if [ ${BENCHMARK_LOGGING} == "Y" ]; then
        # verbose logging
        echo "*** verbose benchmark logging enabled ***"
        check_memory &
        MEM_PID+=("$!")
        iostat -dxm $IOSTAT_INTERVAL $IOSTAT_ROUNDS  > $LOG_NAME_IOSTAT &
        dstat -t -v --nocolor --output $LOG_NAME_DSTAT_CSV $DSTAT_INTERVAL $DSTAT_ROUNDS > $LOG_NAME_DSTAT &
        rm -f $LOG_NAME_INXI
        (x=1; while [ $x -le $DSTAT_ROUNDS ]; do inxi -C -c 0 >> $LOG_NAME_INXI; sleep $DSTAT_INTERVAL; x=$(( $x + 1 )); done) &
    fi
    sysbench_run oltp $MYSQL_DATABASE $RUN_TIME_SECONDS
    sysbench $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=$LOGS/ps_socket.sock --percentile=99 run | tee $LOG_NAME
    sleep 6
    result_set+=(`grep  "queries:" $LOG_NAME | cut -d'(' -f2 | awk '{print $1 ","}'`)
  done

  pkill -f dstat
  pkill -f iostat
  kill -9 ${MEM_PID[@]}
  timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$LOGS/ps_socket.sock shutdown > /dev/null 2>&1
  ps -ef | grep 'ps_socket' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  for i in {0..7}; do if [ -z ${result_set[i]} ]; then  result_set[i]='0,' ; fi; done
  echo "[ '${BUILD_NUMBER}', ${result_set[*]} ]," >> ${LOGS}/sysbench_${BENCH_ID}_perf_result_set.txt
  unset result_set
  DATE=`date +"%Y%m%d%H%M%S"`
  tarFileName="sysbench_${BENCH_ID}_perf_result_set_${BUILD_NUMBER}_${DATE}.tar.gz"
  tar czvf ${tarFileName} ${MYSQL_NAME}* ${LOGS}/master.err
  mkdir -p ${SCP_TARGET}/${BUILD_NUMBER}/${BENCH_SUITE}/${BENCH_ID}
  BACKUP_FILES="${SCP_TARGET}/${BUILD_NUMBER}/${BENCH_SUITE}/${BENCH_ID}"
  cp ${tarFileName} ${BACKUP_FILES}
  rm -rf ${MYSQL_NAME}*
  rm -rf ${DATA_DIR}
}

# **********************************************************************************************
# sysbench
# **********************************************************************************************
export threadCountList="0001 0004 0016 0064 0128 0256 0512 1024"
export WARMUP=Y
export BENCHMARK_LOGGING=Y
WARMUP_TIME_SECONDS=${WARMUP_TIME_SECONDS:-600}
export RUN_TIME_SECONDS=${RUN_TIME_SECONDS:-300}
export REPORT_INTERVAL=10
export IOSTAT_INTERVAL=10
export IOSTAT_ROUNDS=$[RUN_TIME_SECONDS/IOSTAT_INTERVAL+1]
export DSTAT_INTERVAL=10
export DSTAT_ROUNDS=$[RUN_TIME_SECONDS/DSTAT_INTERVAL+1]
export BENCH_SUITE=sysbench

# CPU bound performance run
export DATASIZE=5M
export INNODB_CACHE=25G
export NUM_TABLES=16
export RAND_TYPE=uniform
export BENCH_ID=innodb-${NUM_TABLES}x${DATASIZE}-${RAND_TYPE}-cpubound

start_ps
sysbench_rw_run

# IO bound performance run
export DATASIZE=5M
export INNODB_CACHE=15G
export NUM_TABLES=16
export RAND_TYPE=uniform
export BENCH_ID=innodb-${NUM_TABLES}x${DATASIZE}-${RAND_TYPE}-iobound

start_ps
sysbench_rw_run

# CPU bound performance run
export DATASIZE=1M
export INNODB_CACHE=5G
export RAND_TYPE=uniform
export BENCH_ID=innodb-${NUM_TABLES}x${DATASIZE}-${RAND_TYPE}-cpubound

start_ps
sysbench_rw_run

# IO bound performance run
export DATASIZE=1M
export INNODB_CACHE=1G
export RAND_TYPE=uniform
export BENCH_ID=innodb-${NUM_TABLES}x${DATASIZE}-${RAND_TYPE}-iobound

start_ps
sysbench_rw_run

#Generate graph
VERSION_INFO=`$DB_DIR/bin/mysqld --version | cut -d' ' -f2-`
UPTIME_HOUR=`uptime -p`
SYSTEM_LOAD=`uptime | sed 's|  | |g' | sed -e 's|.*user*.,|System|'`
MEM=`free -g | grep "Mem:" | awk '{print "Total:"$2"GB  Used:"$3"GB  Free:"$4"GB" }'`
if [ ! -f $LOGS/hw.info ];then
  if [ -f /etc/redhat-release ]; then
    RELEASE=`cat /etc/redhat-release`
  else
    RELEASE=`cat /etc/issue`
  fi
  KERNEL=`uname -r`
  echo "HW info | $RELEASE $KERNEL"  > $LOGS/hw.info
fi
echo "Build #$BUILD_NUMBER | `date +'%d-%m-%Y | %H:%M'` | $VERSION_INFO | $UPTIME_HOUR | $SYSTEM_LOAD | Memory: $MEM " >> $LOGS/build_info.log
$SCRIPT_DIR/multibench_html_gen.sh $LOGS
cat ${LOGS}/sysbench_*_perf_result_set.txt > ${LOGS}/sysbench_${BUILD_NUMBER}_full_result_set.txt
cat ${LOGS}/sysbench_*_perf_result_set.txt

exit 0
