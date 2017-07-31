#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC
# This will help us to test replication features

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
PS_START_TIMEOUT=60

cd $WORKDIR

# For local run - User Configurable Variables
if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

if [ -z ${SDURATION} ]; then
  SDURATION=30
fi

if [ -z ${SST_METHOD} ]; then
  SST_METHOD=rsync
fi

if [ -z ${TSIZE} ]; then
  TSIZE=5000
fi

if [ -z ${NUMT} ]; then
  NUMT=16
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=16
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
mkdir -p $WORKDIR/logs

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/logs/ps_async_test.log; fi
}

#Kill existing mysqld process
ps -ef | grep 'ps[0-9].sock' | grep ${BUILD_NUMBER} | grep -v grep | awk '{print $2}' | xargs kill -9 >/dev/null 2>&1 || true

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

trap cleanup EXIT KILL

#Check PS binary tar ball
PS_TAR=`ls -1td ?ercona-?erver* | grep ".tar" | head -n1`
if [ ! -z $PS_TAR ];then
  tar -xzf $PS_TAR
  PSBASE=`ls -1td ?ercona-?erver* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PSBASE/bin:$PATH"
fi
PS_BASEDIR="${ROOT_FS}/$PSBASE"

#Check Percona Toolkit binary tar ball
PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
if [ ! -z $PT_TAR ];then
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
else
  wget https://www.percona.com/downloads/percona-toolkit/2.2.16/tarball/percona-toolkit-2.2.16.tar.gz
  PT_TAR=`ls -1td ?ercona-?oolkit* | grep ".tar" | head -n1`
  tar -xzf $PT_TAR
  PTBASE=`ls -1td ?ercona-?oolkit* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PTBASE/bin:$PATH"
fi

#Check sysbench 
if [[ ! -e `which sysbench` ]];then 
    echoit "Sysbench not found" 
    exit 1
fi
echoit "Note: Using sysbench at $(which sysbench)"

#sysbench command should compatible with versions 0.5 and 1.0
sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --mysql-user=root  --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=root  --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql --db-ps-mode=disable"
    fi
  fi
}

#mysql install db check
if [ "$(${PS_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.7" ]; then
  MID="${PS_BASEDIR}/bin/mysqld --no-defaults --initialize-insecure --basedir=${PS_BASEDIR}"
elif [ "$(${PS_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" == "5.6" ]; then
  MID="${PS_BASEDIR}/scripts/mysql_install_db --no-defaults --basedir=${PS_BASEDIR}"
fi

echoit "Setting PXC/PS Port"
ADDR="127.0.0.1"
RPORT=$(( (RANDOM%21 + 10)*1000 ))
LADDR="$ADDR:$(( RPORT + 8 ))"

SUSER=root
SPASS=

#Check command failure
check_cmd(){
  MPID=$1
  ERROR_MSG=$2
  if [ ${MPID} -ne 0 ]; then echoit "ERROR: $ERROR_MSG. Terminating!"; exit 1; fi
}

#Async replication test
function async_rpl_test(){
  MYEXTRA_CHECK=$1
  if [ "$MYEXTRA_CHECK" == "GTID" ]; then
    MYEXTRA="--gtid-mode=ON --log-slave-updates --enforce-gtid-consistency"
  else 
    MYEXTRA="--log-slave-updates"
  fi
  MYEXTRA="$MYEXTRA --binlog-stmt-cache-size=1M"
  function ps_start(){
    INTANCES="$1"
    if [ -z $INTANCES ];then
      INTANCES=1
    fi
    for i in `seq 1 $INTANCES`;do
      STARTUP_OPTION="$2"
      RBASE1="$(( (RPORT + ( 100 * $i )) + $i ))"
      echoit "Starting independent PS node${i}.."
      node="${WORKDIR}/psnode${i}"
      rm -rf $node
      if [ "$(${PS_BASEDIR}/bin/mysqld --version | grep -oe '5\.[567]' | head -n1)" != "5.7" ]; then
        mkdir -p $node
      fi

      ${MID} --datadir=$node  > ${WORKDIR}/logs/psnode${i}.err 2>&1 || exit 1;
  
      ${PS_BASEDIR}/bin/mysqld --no-defaults --defaults-group-suffix=.2 \
       --basedir=${PS_BASEDIR} $STARTUP_OPTION --datadir=$node \
       --innodb_file_per_table --default-storage-engine=InnoDB \
       --binlog-format=ROW --log-bin=mysql-bin --server-id=20${i} $MYEXTRA \
       --innodb_flush_method=O_DIRECT --core-file --loose-new \
       --sql-mode=no_engine_substitution --loose-innodb --secure-file-priv= \
       --log-error=$WORKDIR/logs/psnode${i}.err --report-host=$ADDR --report-port=$RBASE1 \
       --socket=/tmp/ps${i}.sock  --log-output=none \
       --port=$RBASE1 --master-info-repository=TABLE --relay-log-info-repository=TABLE > $WORKDIR/logs/psnode${i}.err 2>&1 &
       
      for X in $(seq 0 ${PS_START_TIMEOUT}); do
        sleep 1
        if ${PS_BASEDIR}/bin/mysqladmin -uroot -S/tmp/ps${i}.sock ping > /dev/null 2>&1; then
          break
        fi
        if [ $X -eq ${PS_START_TIMEOUT} ]; then
          echoit "PS startup failed.."
          grep "ERROR" ${WORKDIR}/logs/psnode${i}.err
          exit 1
          fi
      done
    done
  }
  
  function run_pt_table_checksum(){
    DATABASES=$1
    LOG_FILE=$2
    pt-table-checksum S=/tmp/ps1.sock,u=root -d $DATABASES --recursion-method hosts --no-check-binlog-format
    check_cmd $?
  }
  
  function invoke_slave(){
    MASTER_SOCKET=$1
    SLAVE_SOCKET=$2
    REPL_STRING=$3
    ${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -e"FLUSH LOGS"
    MASTER_LOG_FILE=`${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "show master logs" | awk '{print $1}' | tail -1`
    MASTER_HOST_PORT=`${PS_BASEDIR}/bin/mysql -uroot --socket=$MASTER_SOCKET -Bse "select @@port"`
    if [ "$MYEXTRA_CHECK" == "GTID" ]; then
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_AUTO_POSITION=1 $REPL_STRING"
    else
      ${PS_BASEDIR}/bin/mysql -uroot --socket=$SLAVE_SOCKET -e"CHANGE MASTER TO MASTER_HOST='${ADDR}', MASTER_PORT=$MASTER_HOST_PORT, MASTER_USER='root', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=4 $REPL_STRING"
    fi
  }    
  
  function slave_startup_check(){
    SOCKET_FILE=$1
    SLAVE_STATUS=$2
    ERROR_LOG=$3
    MSR_SLAVE_STATUS=$4
    SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while ! [[  "$SB_MASTER" =~ ^[0-9]+$ ]]; do
      SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status $MSR_SLAVE_STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      let COUNTER=COUNTER+1
      if [ $COUNTER -eq 10 ];then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" > $SLAVE_STATUS
        echoit "Slave is not started yet. Please check error log and slave status : $ERROR_LOG, $SLAVE_STATUS"
        exit 1
      fi 
      sleep 1;
    done
  }
  
  function slave_sync_check(){
    SOCKET_FILE=$1
    SLAVE_STATUS=$2
    ERROR_LOG=$3
    SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    COUNTER=0
    while [ $SB_MASTER -gt 0 ]; do
      SB_MASTER=`${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_MASTER" =~ ^[0-9]+$ ]]; then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=$SOCKET_FILE -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echoit "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi
      let COUNTER=COUNTER+1
      sleep 5
      if [ $COUNTER -eq 300 ]; then
        echoit "WARNING! Seems slave second behind master is not moving forward, skipping slave sync status check"
        break
      fi
    done
  }

  function async_sysbench_rw_run(){
    MASTER_DB=$1
    SLAVE_DB=$2
    MASTER_SOCKET=$3
    SLAVE_SOCKET=$4   
    #OLTP RW run on master
    echoit "OLTP RW run on master (Database: $MASTER_DB)"
    sysbench_run oltp $MASTER_DB
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$MASTER_SOCKET run  > $WORKDIR/logs/sysbench_master_rw.log 2>&1 &
    #check_cmd $? "Failed to execute sysbench oltp read/write run on master ($MASTER_SOCKET)" 
    
    #OLTP RW run on slave
    echoit "OLTP RW run on slave (Database: $SLAVE_DB)"
    sysbench_run oltp $SLAVE_DB
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SLAVE_SOCKET run  > $WORKDIR/logs/sysbench_slave_rw.log 2>&1 
    #check_cmd $? "Failed to execute sysbench oltp read/write run on slave($SLAVE_SOCKET)"  
  }
  
  function async_sysbench_load(){
    DATABASE_NAME=$1
    SOCKET=$2  
    echoit "Sysbench Run: Prepare stage (Database: $DATABASE_NAME)"
    sysbench_run load_data $DATABASE_NAME
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=$SOCKET prepare  > $WORKDIR/logs/sysbench_prepare.txt 2>&1
    check_cmd $?
  }
  
  function master_slave_test(){
    echoit "******************** $MYEXTRA_CHECK master slave test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 2
    
    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"

    echoit "Checking slave startup"
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists sbtest_ps_slave;create database sbtest_ps_slave;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
    async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"
    async_sysbench_load sbtest_ps_slave "/tmp/ps2.sock"
    
    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave "/tmp/ps1.sock" "/tmp/ps2.sock"
    sleep 5
    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    sleep 10
    echoit "1. PS master slave: Checksum result."
    run_pt_table_checksum "sbtest_ps_master" "$WORKDIR/logs/master_slave_checksum.log"
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }

  function master_multi_slave_test(){
    echoit "********************$MYEXTRA_CHECK master multiple slave test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 4
    
    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps1.sock" "/tmp/ps3.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps1.sock" "/tmp/ps4.sock" ";START SLAVE;"
    
    echoit "Checking slave startup"
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    slave_startup_check "/tmp/ps3.sock" "$WORKDIR/logs/slave_status_psnode3.log" "$WORKDIR/logs/psnode3.err"
    slave_startup_check "/tmp/ps4.sock" "$WORKDIR/logs/slave_status_psnode4.log" "$WORKDIR/logs/psnode4.err"
    
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"drop database if exists sbtest_ps_slave_1;create database sbtest_ps_slave_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e"drop database if exists sbtest_ps_slave_2;create database sbtest_ps_slave_2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps4.sock -e"drop database if exists sbtest_ps_slave_3;create database sbtest_ps_slave_3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"drop database if exists sbtest_ps_master;create database sbtest_ps_master;"
    async_sysbench_load sbtest_ps_master "/tmp/ps1.sock"
    async_sysbench_load sbtest_ps_slave_1 "/tmp/ps2.sock"
    async_sysbench_load sbtest_ps_slave_2 "/tmp/ps3.sock"
    async_sysbench_load sbtest_ps_slave_3 "/tmp/ps4.sock"
    
    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave_1 "/tmp/ps1.sock" "/tmp/ps2.sock"
    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave_2 "/tmp/ps1.sock" "/tmp/ps3.sock"
    async_sysbench_rw_run sbtest_ps_master sbtest_ps_slave_3 "/tmp/ps1.sock" "/tmp/ps4.sock"
    sleep 5
    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    slave_sync_check "/tmp/ps3.sock" "$WORKDIR/logs/slave_status_psnode3.log" "$WORKDIR/logs/psnode3.err"
    slave_sync_check "/tmp/ps4.sock" "$WORKDIR/logs/slave_status_psnode4.log" "$WORKDIR/logs/psnode4.err"
    sleep 10
    echoit "2. PS master multi slave: Checksum result."
    run_pt_table_checksum "sbtest_ps_master" "$WORKDIR/logs/master_multi_slave_checksum.log"
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps4.sock -u root shutdown
  }

  function master_master_test(){
    echoit "********************$MYEXTRA_CHECK master master test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 2
    
    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps2.sock" "/tmp/ps1.sock" ";START SLAVE;"
    
    echoit "Checking slave startup"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"
    
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"drop database if exists sbtest_ps_master_1;create database sbtest_ps_master_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e"drop database if exists sbtest_ps_master_1;create database sbtest_ps_master_1;"

    async_sysbench_load sbtest_ps_master_1 "/tmp/ps1.sock"
    async_sysbench_load sbtest_ps_master_2 "/tmp/ps2.sock"
	
    async_sysbench_rw_run sbtest_ps_master_1 sbtest_ps_master_2 "/tmp/ps1.sock" "/tmp/ps2.sock"
	
    sleep 5
    echoit "Checking slave sync status"
    slave_sync_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"
    slave_sync_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err"

    sleep 10
    echoit "3. PS master master: Checksum result."
    run_pt_table_checksum "sbtest_ps_master" "$WORKDIR/logs/master_multi_slave_checksum.log"
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }
  
  function msr_test(){
    echo "********************$MYEXTRA_CHECK multi source replication test ************************"
    #PS server initialization
    echoit "PS server initialization"
    ps_start 4
    echo "Sysbench Run for replication master master test : Prepare stage"
    invoke_slave "/tmp/ps2.sock" "/tmp/ps1.sock" "FOR CHANNEL 'master1';"
    invoke_slave "/tmp/ps3.sock" "/tmp/ps1.sock" "FOR CHANNEL 'master2';"
    invoke_slave "/tmp/ps4.sock" "/tmp/ps1.sock" "FOR CHANNEL 'master3';"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e"START SLAVE;"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err" "for channel 'master1'"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err" "for channel 'master2'"
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err" "for channel 'master3'"
    
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists msr_db_master1;create database msr_db_master1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps3.sock -e "drop database if exists msr_db_master2;create database msr_db_master2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps4.sock -e "drop database if exists msr_db_master3;create database msr_db_master3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists msr_db_slave;create database msr_db_slave;"
    sleep 5 
    # Sysbench dataload for MSR test
    async_sysbench_load msr_db_master1 "/tmp/ps2.sock"
    async_sysbench_load msr_db_master2 "/tmp/ps3.sock"
    async_sysbench_load msr_db_master3 "/tmp/ps4.sock"
    
    sysbench_run oltp msr_db_master1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_ps_channel1_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp msr_db_master2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps3.sock  run  > $WORKDIR/logs/sysbench_ps_channel2_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp msr_db_master3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps4.sock  run  > $WORKDIR/logs/sysbench_ps_channel3_rw.log 2>&1 
    check_cmd $?
    
    sleep 10
    SB_CHANNEL1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master1'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master2'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_CHANNEL3=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
  
    if ! [[ "$SB_CHANNEL1" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL2" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
      exit 1
    fi
    if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
      echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
      exit 1
    fi
    
    while [ $SB_CHANNEL3 -gt 0 ]; do
      SB_CHANNEL3=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status for channel 'master3'\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_CHANNEL3" =~ ^[0-9]+$ ]]; then
        echo "Slave is not started yet. Please check error log : $WORKDIR/logs/psnode1.err"
        exit 1
      fi
      sleep 5
    done
    sleep 10
    echoit "4. multi source replication: Checksum result."
    run_pt_table_checksum "msr_db_master1,msr_db_master2,msr_db_master3" "$WORKDIR/logs/msr_checksum.log"
    #Shutdown PS servers for MSR test
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps3.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps4.sock -u root shutdown
  }
    
  function mtr_test(){
    echo "********************$MYEXTRA_CHECK multi thread replication test ************************"  
    #PS server initialization
    echoit "PS server initialization"
    ps_start 3 "--slave-parallel-workers=5"

    echo "Sysbench Run for replication master master test : Prepare stage"
    invoke_slave "/tmp/ps1.sock" "/tmp/ps2.sock" ";START SLAVE;"
    invoke_slave "/tmp/ps2.sock" "/tmp/ps1.sock" ";START SLAVE;"
    
    slave_startup_check "/tmp/ps2.sock" "$WORKDIR/logs/slave_status_psnode2.log" "$WORKDIR/logs/psnode2.err" 
    slave_startup_check "/tmp/ps1.sock" "$WORKDIR/logs/slave_status_psnode1.log" "$WORKDIR/logs/psnode1.err"

    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_1;create database mtr_db_ps1_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_2;create database mtr_db_ps1_2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_3;create database mtr_db_ps1_3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_4;create database mtr_db_ps1_4;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -e "drop database if exists mtr_db_ps1_5;create database mtr_db_ps1_5;"
  
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_1;create database mtr_db_ps2_1;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_2;create database mtr_db_ps2_2;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_3;create database mtr_db_ps2_3;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_4;create database mtr_db_ps2_4;"
    ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -e "drop database if exists mtr_db_ps2_5;create database mtr_db_ps2_5;"
 
    sleep 5 
    # Sysbench dataload for MTR test
    echoit "Sysbench dataload for MTR test"
    async_sysbench_load mtr_db_ps1_1 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_2 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_3 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_4 "/tmp/ps1.sock"
    async_sysbench_load mtr_db_ps1_5 "/tmp/ps1.sock"

    async_sysbench_load mtr_db_ps2_1 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_2 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_3 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_4 "/tmp/ps2.sock"
    async_sysbench_load mtr_db_ps2_5 "/tmp/ps2.sock"
    
    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_ps1_1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_1_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps1_2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_2_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps1_3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_3_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps1_4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_4_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps1_5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps1.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps1_5_rw.log 2>&1 &
    check_cmd $?
    # Sysbench RW MTR test run...
    sysbench_run oltp mtr_db_ps2_1
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_1_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps2_2
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_2_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps2_3
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_3_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps2_4
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_4_rw.log 2>&1 &
    check_cmd $?
    sysbench_run oltp mtr_db_ps2_5
    $SBENCH $SYSBENCH_OPTIONS --mysql-socket=/tmp/ps2.sock  run  > $WORKDIR/logs/sysbench_mtr_db_ps2_5_rw.log 2>&1 
    check_cmd $?
    sleep 10
    SB_PS_1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
    SB_PS_2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`

    while [ $SB_PS_1 -gt 0 ]; do
      SB_PS_1=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PS_1" =~ ^[0-9]+$ ]]; then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps2.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode2.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode2.err,  $WORKDIR/logs/slave_status_psnode2.log"
        exit 1
      fi
      sleep 5
    done

    while [ $SB_PS_2 -gt 0 ]; do
      SB_PS_2=`$PS_BASEDIR/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" | grep Seconds_Behind_Master | awk '{ print $2 }'`
      if ! [[ "$SB_PS_2" =~ ^[0-9]+$ ]]; then
        ${PS_BASEDIR}/bin/mysql -uroot --socket=/tmp/ps1.sock -Bse "show slave status\G" > $WORKDIR/logs/slave_status_psnode1.log
        echo "Slave is not started yet. Please check error log and slave status : $WORKDIR/logs/psnode1.err,  $WORKDIR/logs/slave_status_psnode1.log"
        exit 1
      fi
      sleep 5
    done

    sleep 10
    echoit "5. multi thread replication: Checksum result."
    run_pt_table_checksum "mtr_db_ps2_1,mtr_db_ps2_2,mtr_db_ps2_3,mtr_db_ps2_4,mtr_db_ps2_5,mtr_db_ps2_1,mtr_db_ps2_2,mtr_db_ps2_3,mtr_db_ps2_4,mtr_db_ps2_5" "$WORKDIR/logs/mtr_checksum.log"
    #Shutdown PS servers
    echoit "Shuttingdown PS servers"
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps1.sock -u root shutdown
    $PS_BASEDIR/bin/mysqladmin  --socket=/tmp/ps2.sock -u root shutdown
  }
  master_slave_test
  master_multi_slave_test
  master_master_test
  msr_test
  mtr_test
}

async_rpl_test
async_rpl_test GTID
