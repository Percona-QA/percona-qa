#!/bin/bash
# set -x
# PS performance benchmark scripts
# Sysbench suite will run performance tests
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
#MYEXTRA=${MYEXTRA:=--disable-log-bin}
#TASKSET_MYSQLD=${TASKSET_MYSQLD:=taskset -c 0}
#TASKSET_SYSBENCH=${TASKSET_SYSBENCH:=taskset -c 1}

# Check if workdir was set by Jenkins, otherwise this is presumably a local run
if [ -z ${BIG_DIR} ]; then
  export BIG_DIR=${PWD}
fi

command -v cpupower >/dev/null 2>&1 || { echo >&2 "cpupower is not installed. Aborting."; exit 1; }

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
  if [ ! -f $1 ]; then
    echo "[mysqld]" > $1
    echo "sync_binlog=0" >> $1
    echo "core-file" >> $1
    echo "max-connections=1048" >> $1
  fi
}

# make sure we have passed basedir parameter for this benchmark run
if [ -z $2 ]; then usage "ERROR: No valid parameter passed.  Need relative workdir (1st option) and relative basedir (2nd option) settings. Retry."; fi

export BENCH_NUMBER=$1
export BENCH_DIR=$BIG_DIR/$1
export DB_DIR=$BENCH_DIR/$2
export DATA_DIR=$BENCH_DIR/datadir
export LOGS=$BENCH_DIR/logs
mkdir -p $LOGS
cd $BIG_DIR
if [ -z "$3" ]; then
  export CONFIG_FILES=$BENCH_DIR/my.cnf
  rm -rf $CONFIG_FILES
  create_mysql_cnf_file $CONFIG_FILES
else
  export CONFIG_FILES="$3"
fi
echo "Copying server binaries from $BIG_DIR/$2 to $BENCH_DIR"
cp -r $BIG_DIR/$2 $BENCH_DIR

export MYSQL_VERSION=`$DB_DIR/bin/mysqld --version | awk '{ print $3}'`

archives() {
  tar czf ${BIG_DIR}/results-${BENCH_NUMBER}.tar.gz ${BENCH_NUMBER}/logs --transform "s+^${BENCH_NUMBER}/logs++"
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

function sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  SDURATION="$3"
  if [ "$TEST_TYPE" == "load_data" ];then
    SYSBENCH_OPTIONS="$SYSBENCH_DIR/sysbench/oltp_insert.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --threads=$NUM_TABLES --db-driver=mysql"
  elif [ "$TEST_TYPE" == "oltp" ];then
    SYSBENCH_OPTIONS="$SYSBENCH_DIR/sysbench/oltp_read_write.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER  --threads=$num_threads --time=$SDURATION --warmup-time=$WARMUP_TIME_SECONDS --report-interval=10 --events=1870000000 --db-driver=mysql --non_index_updates=1 --db-ps-mode=disable"
  elif [ "$TEST_TYPE" == "oltp_read" ];then
    SYSBENCH_OPTIONS="$SYSBENCH_DIR/sysbench/oltp_read_only.lua --table-size=$NUM_ROWS --tables=$NUM_TABLES --mysql-db=$DB --mysql-user=$SUSER --threads=$num_threads --time=$SDURATION --report-interval=10 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
  fi
}

function start_ps_node(){
  ps -ef | grep 'ps_socket.sock' | grep ${BENCH_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  EXTRA_PARAMS=$MYEXTRA
  EXTRA_PARAMS+=" --innodb-buffer-pool-size=$INNODB_CACHE"
  RBASE="$(( RBASE + 100 ))"
  if [ "$1" == "startup" ];then
    node="${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE}"
    if [ ! -d $node ]; then
      ${TASKSET_MYSQLD} ${DB_DIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${DB_DIR} --datadir=$node  > $LOGS/startup.err 2>&1
    fi
    EXTRA_PARAMS+=" --disable-log-bin"
  else
    node="${DATA_DIR}"
  fi

  MYSQLD_OPTIONS="--defaults-file=${CONFIG_FILE} --datadir=$node --basedir=${DB_DIR} $EXTRA_PARAMS --log-error=${LOGS_CONFIG}/master.err --socket=$MYSQL_SOCKET --port=$RBASE"
  echo "Starting Percona Server with options $MYSQLD_OPTIONS"
  ${TASKSET_MYSQLD} ${DB_DIR}/bin/mysqld $MYSQLD_OPTIONS > ${LOGS_CONFIG}/master.err 2>&1 &

  for X in $(seq 0 ${PS_START_TIMEOUT}); do
    sleep 1
    if ${DB_DIR}/bin/mysqladmin -uroot -S$MYSQL_SOCKET ping > /dev/null 2>&1; then
      echo "Started Percona Server. Socket : $MYSQL_SOCKET"
      break
    fi
  done
  ${DB_DIR}/bin/mysqladmin -uroot -S$MYSQL_SOCKET ping > /dev/null 2>&1 || { echo “Couldn\'t connect $MYSQL_SOCKET” && exit 0; }

  if [ "$1" == "startup" ];then
    echo "Creating data directory in $node"
    ${DB_DIR}/bin/mysql -uroot -S$MYSQL_SOCKET -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE" 2>&1
    sysbench_run load_data $MYSQL_DATABASE
    time ${TASKSET_SYSBENCH} sysbench $SYSBENCH_OPTIONS --mysql-socket=$MYSQL_SOCKET prepare 2>&1 | tee $LOGS/sysbench_prepare.log
    echo -e "Data directory in $node created\nShutting mysqld down"
    time ${DB_DIR}/bin/mysqladmin -uroot --socket=$MYSQL_SOCKET shutdown > /dev/null 2>&1
  fi
}

function check_memory(){
  CHECK_PID=`ps -ef | grep ps_socket | grep -v grep | awk '{ print $2}'`
  WAIT_TIME_SECONDS=10
  RUN_TIME_SECONDS=$(($RUN_TIME_SECONDS + $WARMUP_TIME_SECONDS))
  while [ ${RUN_TIME_SECONDS} -gt 0 ]; do
    DATE=`date +"%Y%m%d%H%M%S"`
    CURRENT_INFO=`ps -o rss,vsz,pcpu ${CHECK_PID} | tail -n 1`
    echo "${DATE} ${CURRENT_INFO}" >> ${LOG_NAME_MEMORY}
    RUN_TIME_SECONDS=$(($RUN_TIME_SECONDS - $WAIT_TIME_SECONDS))
    sleep ${WAIT_TIME_SECONDS}
  done
}

function restore_address_randomization(){
    CURRENT_ASLR=`cat /proc/sys/kernel/randomize_va_space`
    sudo sh -c "echo $PREVIOUS_ASLR > /proc/sys/kernel/randomize_va_space"
    echo "Resoring /proc/sys/kernel/randomize_va_space from $CURRENT_ASLR to `cat /proc/sys/kernel/randomize_va_space`"
}

function disable_address_randomization(){
    PREVIOUS_ASLR=`cat /proc/sys/kernel/randomize_va_space`
    sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"
    echo "Setting /proc/sys/kernel/randomize_va_space from $PREVIOUS_ASLR to `cat /proc/sys/kernel/randomize_va_space`"
}

function restore_turbo_boost(){
  echo "Restore turbo boost with $SCALING_DRIVER scaling driver"

  if [[ ${SCALING_DRIVER} == "intel_pstate" || ${SCALING_DRIVER} == "intel_cpufreq" ]]; then
    CURRENT_TURBO=`cat /sys/devices/system/cpu/intel_pstate/no_turbo`
    sudo sh -c "echo $PREVIOUS_TURBO > /sys/devices/system/cpu/intel_pstate/no_turbo"
    echo "Setting /sys/devices/system/cpu/intel_pstate/no_turbo from $CURRENT_TURBO to $PREVIOUS_TURBO"
  else
    CURRENT_TURBO=`cat /sys/devices/system/cpu/cpufreq/boost`
    sudo sh -c "echo $PREVIOUS_TURBO > /sys/devices/system/cpu/cpufreq/boost"
    echo "Setting /sys/devices/system/cpu/cpufreq/boost from $CURRENT_TURBO to $PREVIOUS_TURBO"
  fi
}

function disable_turbo_boost(){
  SCALING_DRIVER=`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver`
  echo "Using $SCALING_DRIVER scaling driver"

  if [[ ${SCALING_DRIVER} == "intel_pstate" || ${SCALING_DRIVER} == "intel_cpufreq" ]]; then
    PREVIOUS_TURBO=`cat /sys/devices/system/cpu/intel_pstate/no_turbo`
    sudo sh -c "echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo"
    echo "Setting /sys/devices/system/cpu/intel_pstate/no_turbo from $PREVIOUS_TURBO to `cat /sys/devices/system/cpu/intel_pstate/no_turbo`"
  else
    PREVIOUS_TURBO=`cat /sys/devices/system/cpu/cpufreq/boost`
    sudo sh -c "echo 0 > /sys/devices/system/cpu/cpufreq/boost"
    echo "Setting /sys/devices/system/cpu/cpufreq/boost from $PREVIOUS_TURBO to `cat /sys/devices/system/cpu/cpufreq/boost`"
  fi
}

function restore_scaling_governor(){
  CURRENT_GOVERNOR=`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
  sudo cpupower frequency-set -g $PREVIOUS_GOVERNOR
  echo "Changed scaling governor from $CURRENT_GOVERNOR to `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`"
  sudo cpupower frequency-info
}

function change_scaling_governor(){
  PREVIOUS_GOVERNOR=`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
  sudo cpupower frequency-set -g $1
  echo "Changed scaling governor from $PREVIOUS_GOVERNOR to `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`"
  sudo cpupower frequency-info
}

function enable_idle_states(){
  sudo cpupower idle-set --enable-all
  sudo cpupower idle-info
}

function disable_idle_states(){
  sudo cpupower idle-set --disable-by-latency 0
  sudo cpupower idle-info
}

function drop_caches(){
  echo "Dropping caches"
  sync
  sudo sh -c 'sysctl -q -w vm.drop_caches=3'
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
  ulimit -n 1000000
}

function start_ps(){
  MYSQL_SOCKET=${LOGS}/ps_socket.sock
  timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$MYSQL_SOCKET shutdown > /dev/null 2>&1
  ps -ef | grep 'ps_socket' | grep ${BENCH_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  BIN=`find ${DB_DIR} -maxdepth 2 -name mysqld -type f -o -name mysqld-debug -type f | head -1`;if [ -z $BIN ]; then echo "Assert! mysqld binary '$BIN' could not be read";exit 1;fi
  NUM_ROWS=$(numfmt --from=si $DATASIZE)
  WS_DATADIR="${BIG_DIR}/80_sysbench_data_template"

  drop_caches
  if [ ! -d ${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE} ]; then
    mkdir ${WS_DATADIR} > /dev/null 2>&1
    start_ps_node startup
  fi
  echo "Copying data directory from ${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE} to ${DATA_DIR}"
  rm -rf ${DATA_DIR}
  cp -r ${WS_DATADIR}/datadir_${NUM_TABLES}x${DATASIZE} ${DATA_DIR}
  start_ps_node
}

function sysbench_rw_run(){
  BENCH_ID=innodb-${NUM_TABLES}x${DATASIZE}-${INNODB_CACHE}
  MEM_PID=()
  if [ ${WARMUP} == "Y" ]; then
    #warmup the cache, 64 threads for 10 minutes, don't bother logging
    # *** REMEMBER *** warmmup is READ ONLY!
    num_threads=64
    echo "Warming up for $WARMUP_TIME_AT_START seconds"
    sysbench_run oltp_read $MYSQL_DATABASE $WARMUP_TIME_AT_START
    ${TASKSET_SYSBENCH} sysbench $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=$MYSQL_SOCKET --percentile=99 run > ${LOGS_CONFIG}/sysbench_warmup.log 2>&1
    sleep $[WARMUP_TIME_AT_START/10]
  fi
  echo "Storing Sysbench results in ${WORKSPACE}"
  for num_threads in ${THREADS_LIST}; do
    LOG_NAME_RESULTS=${LOGS_CONFIG}/results-QPS-${BENCH_ID}.txt
    LOG_NAME=${LOGS_CONFIG}/${MYSQL_NAME}-${MYSQL_VERSION}-${BENCH_ID}-$num_threads.txt
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
    ${TASKSET_SYSBENCH} sysbench $SYSBENCH_OPTIONS --rand-type=$RAND_TYPE --mysql-socket=$MYSQL_SOCKET --percentile=99 run | tee $LOG_NAME
    sleep 6
    result_set+=(`grep  "queries:" $LOG_NAME | cut -d'(' -f2 | awk '{print $1 ","}'`)
  done

  pkill -f dstat
  pkill -f iostat
  kill -9 ${MEM_PID[@]}
  timeout --signal=9 20s ${DB_DIR}/bin/mysqladmin -uroot --socket=$MYSQL_SOCKET shutdown > /dev/null 2>&1
  ps -ef | grep 'ps_socket' | grep ${BENCH_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true
  for i in {0..7}; do if [ -z ${result_set[i]} ]; then  result_set[i]='0,' ; fi; done
  echo "[ '${BENCH_NUMBER}_${CONFIG_BASE}_${BENCH_ID}', ${result_set[*]} ]," >> ${LOG_NAME_RESULTS}
  cat ${LOG_NAME_RESULTS} >> ${LOGS}/sysbench_${BENCH_ID}_${BENCH_NUMBER}_perf_result_set.txt
  unset result_set
}

function archive_logs(){
  DATE=`date +"%Y%m%d%H%M%S"`
  tarFileName="sysbench_${BENCH_ID}_perf_result_set_${BENCH_NUMBER}_${DATE}.tar.gz"
  tar czvf ${tarFileName} ${BENCH_NUMBER}/logs --transform "s+^${BENCH_NUMBER}/logs++"

  mkdir -p ${SCP_TARGET}/${BENCH_NUMBER}/${BENCH_SUITE}/${BENCH_ID}
  BACKUP_FILES="${SCP_TARGET}/${BENCH_NUMBER}/${BENCH_SUITE}/${BENCH_ID}"
  cp ${tarFileName} ${BACKUP_FILES}
  rm -rf ${DATA_DIR}
}

# **********************************************************************************************
# sysbench
# **********************************************************************************************
export THREADS_LIST=${THREADS_LIST:="0001 0004 0016 0064 0128 0256 0512 1024"}
export WARMUP=Y
export BENCHMARK_LOGGING=Y
WARMUP_TIME_AT_START=${WARMUP_TIME_AT_START:-600}
export WARMUP_TIME_SECONDS=${WARMUP_TIME_SECONDS:=30}
export RUN_TIME_SECONDS=${RUN_TIME_SECONDS:-600}
export REPORT_INTERVAL=10
export IOSTAT_INTERVAL=10
export IOSTAT_ROUNDS=$[(RUN_TIME_SECONDS+WARMUP_TIME_SECONDS)/IOSTAT_INTERVAL+1]
export DSTAT_INTERVAL=10
export DSTAT_ROUNDS=$[(RUN_TIME_SECONDS+WARMUP_TIME_SECONDS)/DSTAT_INTERVAL+1]
export BENCH_SUITE=sysbench

export INNODB_CACHE=${INNODB_CACHE:-32G}
export NUM_TABLES=${NUM_TABLES:-16}
export DATASIZE=${DATASIZE:-10M}
export RAND_TYPE=${RAND_TYPE:-uniform}

rm -rf ${LOGS}
mkdir -p ${LOGS}
LOGS_CPU=$LOGS/cpu-states.txt

disable_turbo_boost > ${LOGS_CPU}
change_scaling_governor powersave >> ${LOGS_CPU}
disable_idle_states >> ${LOGS_CPU}
disable_address_randomization >> ${LOGS_CPU}

for file in $CONFIG_FILES; do
  if [ ! -f $file ]; then usage "ERROR: Config file $file not found."; fi
  CONFIG_BASE=$(basename ${file%.*})
  LOGS_CONFIG=${LOGS}/${BENCH_NUMBER}-${CONFIG_BASE}
  mkdir -p ${LOGS_CONFIG}
  CONFIG_FILE=${LOGS_CONFIG}/$(basename $file)
  cp $file $CONFIG_FILE
  echo "Using $CONFIG_FILE as mysqld config file"

  start_ps
  sysbench_rw_run
done

restore_turbo_boost >> ${LOGS_CPU}
restore_scaling_governor >> ${LOGS_CPU}
enable_idle_states >> ${LOGS_CPU}
restore_address_randomization >> ${LOGS_CPU}
archive_logs

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
echo "Build #$BENCH_NUMBER | `date +'%d-%m-%Y | %H:%M'` | $VERSION_INFO | $UPTIME_HOUR | $SYSTEM_LOAD | Memory: $MEM " >> $LOGS/build_info.log
$SCRIPT_DIR/multibench_html_gen.sh $LOGS
cat ${LOGS}/sysbench_*_perf_result_set.txt > ${LOGS}/sysbench_${BENCH_NUMBER}_full_result_set.txt
cat ${LOGS}/sysbench_*_perf_result_set.txt

exit 0
