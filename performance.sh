#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Improvement suggestions/ideas
# - Run in memory (/dev/shm) instead? Less real life, but less prone to other disk load

# User settings
SENDMAIL="/usr/sbin/sendmail"
if [ -z "$WORKDIR" ]; then
  WORKDIR=/data/bench/qa
fi
if [ -z "$SYSBENCH_DURATION" ]; then
  SYSBENCH_DURATION=2700
  SYSBENCH_SINGLE_THREAD_DURATION=3600
fi

# Internal settings
MTR_BT=$[$RANDOM % 300 + 1]
PORT=$[20000 + $RANDOM % 9999 + 1]
MULTI_THREAD_COUNT=400
# The first option is the relative workdir
# The second option is the relative basedir
if [ -z $2 ]; then
  echo "No valid parameters were passed. Need relative workdir (1st option) and relative basedir (2nd option) settings. Retry.";
  echo "Usage example:"
  echo "$./performance.sh 100 Percona-Server-5.5.28-rel29.3-435.Linux.x86_64"
  echo "This would lead to $WORKDIR/100 being created, in which testing takes place and"
  echo "$WORKDIR/Percona-Server-5.5.28-rel29.3-435.Linux.x86_64 would be used to test."
  echo "The fixed "root workdir" to which all options are relative is set to $WORKDIR in the script."
  exit 1
else
  WORKDIRSUB=$1
  BASEDIRSUB=$2
fi

# Check if workspace was set by Jenkins, otherwise this is presumably a local run
if [ -z $WORKSPACE ]; then
  echo "Assuming this is a local (i.e. non-Jenkins initiated) run."
  WORKSPACE=$WORKDIR/$WORKDIRSUB
fi

TESTBIN="$WORKDIR/$BASEDIRSUB/mysql-test/lib/v1/mysql-test-run.pl"

echo "Workdir: $WORKDIR/$WORKDIRSUB"
echo "Basedir: $WORKDIR/$BASEDIRSUB"
echo "Testbin: $TESTBIN"

# Check directories & start run if all ok
if [ -d $WORKDIR/$WORKDIRSUB ]; then
  echo "Work directory already exists. Fatal error.";
  exit 1
elif [ ! -d $WORKDIR/$BASEDIRSUB ]; then
  echo "Base directory does not exist. Fatal error.";
  exit 1
elif [ ! -r $TESTBIN ]; then
  echo "mysql-test-run.pl missing ($TESTBIN). Fatal error.";
  exit 1
else
  mkdir $WORKDIR/$WORKDIRSUB/default_run

  # Start the server with default server settings.
  cd $WORKDIR/$BASEDIRSUB/mysql-test/
  set -o pipefail; MTR_BUILD_THREAD=$MTR_BT; perl lib/v1/mysql-test-run.pl \
   --start-and-exit \
   --skip-ndb \
   --vardir=$WORKDIR/$WORKDIRSUB/default_run \
   --master_port=$PORT \
   --mysqld=--core-file \
   --mysqld=--sql-mode=no_engine_substitution \
   --mysqld=--relay-log=slave-relay-bin \
   --mysqld=--loose-innodb \
   --mysqld=--log-output=none \
   --mysqld=--secure-file-priv= \
   --mysqld=--max-connections=900 \
   --mysqld=--socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   1st

  # Sysbench Runs
  ## Prepare/setup
  echo "Sysbench Run: Prepare stage"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua \
   --num-threads=40 \
   --oltp-tables-count=40 --oltp-table-size=1000000 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_prepare.txt 2>&1

  ## OLTP RO Run for memory Warmup
  echo "Sysbench Run: OLTP RO Run for memory Warmup"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=120 --max-requests=1870000000 \
   --oltp-tables-count=30 --mysql-db=test --oltp-read-only --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_ro_run_warm_up.txt 2>&1

  ## OLTP RW Run with default server settings + single threaded + cpubound
  echo "Sysbench Run: OLTP RW testing with default server settings + single threaded + cpubound"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=1 --max-time=$SYSBENCH_SINGLE_THREAD_DURATION --max-requests=1870000000 \
   --oltp-tables-count=10 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_default_rw_single_thread_cpubound.txt 2>&1

  ## OLTP RW Run with default server settings + multiple threaded (700) + cpubound
  echo "Sysbench Run: OLTP RW testing with default server settings + multiple threaded (700) + cpubound"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
   --oltp-tables-count=10 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_default_rw_multi_thread_cpubound.txt 2>&1

  ## Cleanup system
  echo "Sysbench Run: Cleanup stage"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua \
   --num-threads=40 \
   --oltp-tables-count=40 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   cleanup > $WORKDIR/$WORKDIRSUB/sysbench_default_cleanup.txt 2>&1

  # kill current mysql process to start the server with tuned server settings
  pkill -f mysqld
  sleep 5
  mkdir -p $WORKDIR/$WORKDIRSUB/tuned_run
  PS_VERSION=`$WORKDIR/$BASEDIRSUB/bin/mysqld --version | awk '{print $3}' | cut -c1-3`
  if [ $PS_VERSION == "5.6" ];then
    LINK="http://jenkins.percona.com/view/QA/job/percona-server-5.6-qa-performance/plot/"
    # Start 5.6 server with tuned server settings.
    set -o pipefail; MTR_BUILD_THREAD=$MTR_BT; perl lib/v1/mysql-test-run.pl \
     --start-and-exit \
     --skip-ndb \
     --vardir=$WORKDIR/$WORKDIRSUB/tuned_run \
     --master_port=$PORT \
     --mysqld=--core-file \
     --mysqld=--loose-new \
     --mysqld=--sql-mode=no_engine_substitution \
     --mysqld=--relay-log=slave-relay-bin \
     --mysqld=--loose-innodb \
     --mysqld=--secure-file-priv= \
     --mysqld=--max-allowed-packet=16Mb \
     --mysqld=--loose-innodb-status-file=1 \
     --mysqld=--master-retry-count=65535 \
     --mysqld=--skip-name-resolve \
     --mysqld=--socket=$WORKDIR/$WORKDIRSUB/socket.sock \
     --mysqld=--log-output=none \
     --mysqld=--loose-userstat \
     --mysqld=--loose-innodb_lazy_drop_table=1 \
     --mysqld=--innodb-old-blocks_time=0 \
     --mysqld=--innodb-buffer-pool-size=4G \
     --mysqld=--innodb-lru-scan-depth=3000 \
     --mysqld=--innodb-log-file-size=1G \
     --mysqld=--innodb-io-capacity=2000 \
     --mysqld=--innodb-io-capacity-max=4000 \
     --mysqld=--innodb-flush-log-at-trx-commit=1 \
     --mysqld=--innodb-flush-method=O_DIRECT \
     --mysqld=--innodb-checksum-algorithm=crc32 \
     --mysqld=--innodb-log-checksum-algorithm=crc32 \
     --mysqld=--max-connections=900 \
     --mysqld=--innodb-file-per-table=true \
     1st
  elif [ $PS_VERSION == "5.5" ];then
    LINK="http://jenkins.percona.com/view/QA/job/percona-server-5.5-qa-performance/plot/"
    # Start 5.5 server with tuned server settings.
    set -o pipefail; MTR_BUILD_THREAD=$MTR_BT; perl lib/v1/mysql-test-run.pl \
     --start-and-exit \
     --skip-ndb \
     --vardir=$WORKDIR/$WORKDIRSUB/tuned_run \
     --master_port=$PORT \
     --mysqld=--core-file \
     --mysqld=--loose-new \
     --mysqld=--sql-mode=no_engine_substitution \
     --mysqld=--relay-log=slave-relay-bin \
     --mysqld=--loose-innodb \
     --mysqld=--secure-file-priv= \
     --mysqld=--max-allowed-packet=16Mb \
     --mysqld=--loose-innodb-status-file=1 \
     --mysqld=--master-retry-count=65535 \
     --mysqld=--skip-name-resolve \
     --mysqld=--socket=$WORKDIR/$WORKDIRSUB/socket.sock \
     --mysqld=--log-output=none \
     --mysqld=--loose-userstat \
     --mysqld=--loose-innodb_lazy_drop_table=1 \
     --mysqld=--innodb-old-blocks_time=0 \
     --mysqld=--innodb-buffer-pool-size=4G \
     --mysqld=--innodb-log-file-size=1G \
     --mysqld=--innodb-io-capacity=2000 \
     --mysqld=--innodb-flush-log-at-trx-commit=1 \
     --mysqld=--innodb-flush-method=O_DIRECT \
     --mysqld=--innodb-buffer-pool-instances=8 \
     --mysqld=--max-connections=900 \
     --mysqld=--innodb-file-per-table=true \
     1st
  else
   echo "Script is created only for PS version 5.5 and 5.6. Retry.."
   exit 1
  fi

  # Give mysqld a bit of time to stabilize
  sleep 5

  # Sysbench Runs
  ## Prepare/setup
  echo "Sysbench Run: Prepare stage"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua \
   --num-threads=40 \
   --oltp-tables-count=40 --oltp-table-size=1000000 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_prepare.txt 2>&1

  ## OLTP RO Run for memory Warmup
  echo "Sysbench Run: OLTP RO Run for memory Warmup"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=120 --max-requests=1870000000 \
   --oltp-tables-count=30 --mysql-db=test --oltp-read-only --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_ro_run_warm_up.txt 2>&1

  ## OLTP RW Run with Tuned server settings + single threaded + cpubound (10 tables * 1 M Rows each : data size approx = 2.3G)
  echo "Sysbench Run: OLTP RW testing with default server settings + single threaded + cpubound"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=1 --max-time=$SYSBENCH_SINGLE_THREAD_DURATION --max-requests=1870000000 \
   --oltp-tables-count=10 --mysql-db=test --mysql-user=root --db-driver=mysql \
   --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_single_thread_cpubound.txt 2>&1

  ## OLTP RW Run with Tuned server settings + multiple threaded (700) + cpubound (10 tables * 1 M Rows each : data size approx = 2.3G )
  echo "Sysbench Run: OLTP RW testing with default server settings + multiple threaded (700) + cpubound"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
   --oltp-tables-count=10 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_multi_thread_cpubound.txt 2>&1

  ## OLTP RW Run with Tuned server settings + single threaded + iobound (30 tables * 1 M Rows each : data size approx = 6.9G )
  echo "Sysbench Run: OLTP RW testing with tuned server settings + single threaded + iobound"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=1 --max-time=$SYSBENCH_SINGLE_THREAD_DURATION --max-requests=1870000000 \
   --oltp-tables-count=30 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_single_thread_iobound.txt 2>&1

  ## OLTP RW Run with Tuned server settings + multiple threaded (700) + iobound (30 tables * 1 M Rows each : data size approx = 6.9G )
  echo "Sysbench Run: OLTP RW Run with tuned server settings + multiple threaded (700) + iobound"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
   --oltp-tables-count=30 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_multi_thread_iobound.txt 2>&1

  ## Cleanup system
  echo "Sysbench Run: Cleanup stage"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua \
   --num-threads=40 \
   --oltp-tables-count=40 --mysql-db=test --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   cleanup > $WORKDIR/$WORKDIRSUB/sysbench_tuned_cleanup.txt 2>&1

  # Process Results
  RW_DS_CPUBOUND_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_default_rw_single_thread_cpubound.txt | awk '{print $2}' | xargs echo`
  RW_DM_CPUBOUND_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_default_rw_multi_thread_cpubound.txt | awk '{print $2}' | xargs echo`
  RW_TS_CPUBOUND_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_single_thread_cpubound.txt | awk '{print $2}' | xargs echo`
  RW_TM_CPUBOUND_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_multi_thread_cpubound.txt | awk '{print $2}' | xargs echo`
  RW_TS_IOBOUND_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_single_thread_iobound.txt | awk '{print $2}' | xargs echo`
  RW_TM_IOBOUND_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_multi_thread_iobound.txt | awk '{print $2}' | xargs echo`

  ## Current run info to XML for Jenkins
  echo "Storing Sysbench results in $WORKSPACE"
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_st.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_ds_cpu.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_dm_cpu.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_ts_cpu.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_tm_cpu.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_ts_io.xml
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_tm_io.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_st.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_ds_cpu.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_dm_cpu.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_ts_cpu.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_tm_cpu.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_ts_io.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_tm_io.xml
  echo "  <RW_DS_CPUBOUND_QUERIES type=\"result\">$RW_DS_CPUBOUND_QUERIES</RW_DS_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_st.xml
  echo "  <RW_DS_CPUBOUND_QUERIES type=\"result\">$RW_DS_CPUBOUND_QUERIES</RW_DS_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_ds_cpu.xml
  echo "  <RW_DM_CPUBOUND_QUERIES type=\"result\">$RW_DM_CPUBOUND_QUERIES</RW_DM_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results.xml
  echo "  <RW_DM_CPUBOUND_QUERIES type=\"result\">$RW_DM_CPUBOUND_QUERIES</RW_DM_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_dm_cpu.xml
  echo "  <RW_TS_CPUBOUND_QUERIES type=\"result\">$RW_TS_CPUBOUND_QUERIES</RW_TS_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_st.xml
  echo "  <RW_TS_CPUBOUND_QUERIES type=\"result\">$RW_TS_CPUBOUND_QUERIES</RW_TS_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_ts_cpu.xml
  echo "  <RW_TM_CPUBOUND_QUERIES type=\"result\">$RW_TM_CPUBOUND_QUERIES</RW_TM_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results.xml
  echo "  <RW_TM_CPUBOUND_QUERIES type=\"result\">$RW_TM_CPUBOUND_QUERIES</RW_TM_CPUBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_tm_cpu.xml
  echo "  <RW_TS_IOBOUND_QUERIES type=\"result\">$RW_TS_IOBOUND_QUERIES</RW_TS_IOBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_st.xml
  echo "  <RW_TS_IOBOUND_QUERIES type=\"result\">$RW_TS_IOBOUND_QUERIES</RW_TS_IOBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_ts_io.xml
  echo "  <RW_TM_IOBOUND_QUERIES type=\"result\">$RW_TM_IOBOUND_QUERIES</RW_TM_IOBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results.xml
  echo "  <RW_TM_IOBOUND_QUERIES type=\"result\">$RW_TM_IOBOUND_QUERIES</RW_TM_IOBOUND_QUERIES>" >> $WORKSPACE/sysbench_performance_results_tm_io.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_st.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_ds_cpu.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_dm_cpu.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_ts_cpu.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_tm_cpu.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_ts_io.xml
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_tm_io.xml

  ## Compare against previous run
  if [ -r $WORKSPACE/default_rw_ds_cpubound_lastrun.txt -a -r $WORKSPACE/default_rw_dm_cpubound_lastrun.txt -a -r $WORKSPACE/default_rw_ts_cpubound_lastrun.txt -a -r $WORKSPACE/default_rw_tm_cpubound_lastrun.txt -a -r $WORKSPACE/default_rw_ts_iobound_lastrun.txt -a -r $WORKSPACE/default_rw_tm_iobound_lastrun.txt ]; then
    RW_DS_CPUBOUND_QUERIES_LAST=`cat $WORKSPACE/default_rw_ds_cpubound_lastrun.txt`
    RW_DM_CPUBOUND_QUERIES_LAST=`cat $WORKSPACE/default_rw_dm_cpubound_lastrun.txt`
    RW_TS_CPUBOUND_QUERIES_LAST=`cat $WORKSPACE/default_rw_ts_cpubound_lastrun.txt`
    RW_TM_CPUBOUND_QUERIES_LAST=`cat $WORKSPACE/default_rw_tm_cpubound_lastrun.txt`
    RW_TS_IOBOUND_QUERIES_LAST=`cat $WORKSPACE/default_rw_ts_iobound_lastrun.txt`
    RW_TM_IOBOUND_QUERIES_LAST=`cat $WORKSPACE/default_rw_tm_iobound_lastrun.txt`
    echo "================================================================================================================"
    echo "RW_DS_CPUBOUND Last Run: $RW_DS_CPUBOUND_QUERIES_LAST 		| RW_DS_CPUBOUND This Run: $RW_DS_CPUBOUND_QUERIES"
    echo "RW_DM_CPUBOUND Last Run: $RW_DM_CPUBOUND_QUERIES_LAST 		| RW_DM_CPUBOUND This Run: $RW_DM_CPUBOUND_QUERIES"
    echo "RW_TS_CPUBOUND Last Run: $RW_TS_CPUBOUND_QUERIES_LAST 		| RW_TS_CPUBOUND This Run: $RW_TS_CPUBOUND_QUERIES"
    echo "RW_TM_CPUBOUND Last Run: $RW_TM_CPUBOUND_QUERIES_LAST 		| RW_TM_CPUBOUND This Run: $RW_TM_CPUBOUND_QUERIES"
    echo "RW_TS_IOBOUND Last Run: $RW_TS_IOBOUND_QUERIES_LAST  			| RW_TS_IOBOUND This Run: $RW_TS_IOBOUND_QUERIES"
    echo "RW_TM_IOBOUND Last Run: $RW_TM_IOBOUND_QUERIES_LAST  			| RW_TM_IOBOUND This Run: $RW_TM_IOBOUND_QUERIES"
    echo "================================================================================================================"
    RW_DS_CPUBOUND_FACTOR=`echo "scale=2; $RW_DS_CPUBOUND_QUERIES / $RW_DS_CPUBOUND_QUERIES_LAST" | bc`
    RW_DM_CPUBOUND_FACTOR=`echo "scale=2; $RW_DM_CPUBOUND_QUERIES / $RW_DM_CPUBOUND_QUERIES_LAST" | bc`
    RW_TS_CPUBOUND_FACTOR=`echo "scale=2; $RW_TS_CPUBOUND_QUERIES / $RW_TS_CPUBOUND_QUERIES_LAST" | bc`
    RW_TM_CPUBOUND_FACTOR=`echo "scale=2; $RW_TM_CPUBOUND_QUERIES / $RW_TM_CPUBOUND_QUERIES_LAST" | bc`
    RW_TS_IOBOUND_FACTOR=`echo "scale=2; $RW_TS_IOBOUND_QUERIES / $RW_TS_IOBOUND_QUERIES_LAST" | bc`
    RW_TM_IOBOUND_FACTOR=`echo "scale=2; $RW_TM_IOBOUND_QUERIES / $RW_TM_IOBOUND_QUERIES_LAST" | bc`

    RW_DS_CPUBOUND_PERCNT=`echo "$RW_DS_CPUBOUND_FACTOR * 100" | bc | sed 's/\..*//'`
    RW_DM_CPUBOUND_PERCNT=`echo "$RW_DM_CPUBOUND_FACTOR * 100" | bc | sed 's/\..*//'`
    RW_TS_CPUBOUND_PERCNT=`echo "$RW_TS_CPUBOUND_FACTOR * 100" | bc | sed 's/\..*//'`
    RW_TM_CPUBOUND_PERCNT=`echo "$RW_TM_CPUBOUND_FACTOR * 100" | bc | sed 's/\..*//'`
    RW_TS_IOBOUND_PERCNT=`echo "$RW_TS_IOBOUND_FACTOR * 100" | bc | sed 's/\..*//'`
    RW_TM_IOBOUND_PERCNT=`echo "$RW_TM_IOBOUND_FACTOR * 100" | bc | sed 's/\..*//'`
    echo "RW_DS_CPUBOUND Factor: $RW_DS_CPUBOUND_FACTOR ($RW_DS_CPUBOUND_PERCNT%)"
    echo "RW_DM_CPUBOUND Factor: $RW_DM_CPUBOUND_FACTOR ($RW_DM_CPUBOUND_PERCNT%)"
    echo "RW_TS_CPUBOUND Factor: $RW_TS_CPUBOUND_FACTOR ($RW_TS_CPUBOUND_PERCNT%)"
    echo "RW_TM_CPUBOUND Factor: $RW_TM_CPUBOUND_FACTOR ($RW_TM_CPUBOUND_PERCNT%)"
    echo "RW_TS_IOBOUND Factor: $RW_TS_IOBOUND_FACTOR ($RW_TS_IOBOUND_PERCNT%)"
    echo "RW_TM_IOBOUND Factor: $RW_TM_IOBOUND_FACTOR ($RW_TM_IOBOUND_PERCNT%)"
    echo "======================================================================="
    if [ $RW_DS_CPUBOUND_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP RW Run with default server settings + single threaded + cpubound performance"
      echo -e "Subject: Performance Increase for Percona Server $PS_VERSION (default server settings + single threaded + cpubound)\nBig increase in OLTP RW Run with default server settings + single threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_default_rw_single_thread_cpubound_res.txt 2>&1
    elif [ $RW_DS_CPUBOUND_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP RW Run with default server settings + single threaded + cpubound performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server $PS_VERSION (default server settings + single threaded + cpubound)\nBig decrease in OLTP RW Run with default server settings + single threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_default_rw_single_thread_cpubound_res.txt 2>&1
    fi
    if [ $RW_DM_CPUBOUND_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP RW Run with default server settings + multi threaded + cpubound performance"
      echo -e "Subject: Performance Increase for Percona Server $PS_VERSION (default server settings + multi threaded + cpubound)\nBig increase in OLTP RW Run with default server settings + multi threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_default_rw_multi_thread_cpubound_res.txt 2>&1
    elif [ $RW_DM_CPUBOUND_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP RW Run with default server settings + multi threaded + cpubound performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server $PS_VERSION (default server settings + multi threaded + cpubound)\nBig decrease in OLTP RW Run with default server settings + multi threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_default_rw_multi_thread_cpubound_res.txt 2>&1
    fi
    if [ $RW_TS_CPUBOUND_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP RW Run with tuned server settings + single threaded + cpubound performance"
      echo -e "Subject: Performance Increase for Percona Server $PS_VERSION (tuned server settings + single threaded + cpubound)\nBig increase in OLTP RW Run with tuned server settings + single threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_single_thread_cpubound_res.txt 2>&1
    elif [ $RW_TS_CPUBOUND_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP RW Run with tuned server settings + single threaded + cpubound performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server $PS_VERSION (tuned server settings + single threaded + cpubound)\nBig decrease in OLTP RW Run with tuned server settings + single threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_single_thread_cpubound_res.txt 2>&1
    fi
    if [ $RW_TM_CPUBOUND_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP RW Run with tuned server settings + multi threaded + cpubound performance"
      echo -e "Subject: Performance Increase for Percona Server $PS_VERSION (tuned server settings + multi threaded + cpubound)\nBig increase in OLTP RW Run with tuned server settings + multi threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_multi_thread_cpubound_res.txt 2>&1
    elif [ $RW_TM_CPUBOUND_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP RW Run with tuned server settings + multi threaded + cpubound performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server $PS_VERSION (tuned server settings + multi threaded + cpubound)\nBig decrease in OLTP RW Run with tuned server settings + multi threaded + cpubound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_multi_thread_cpubound_res.txt 2>&1
    fi
	if [ $RW_TS_IOBOUND_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP RW Run with tuned server settings + single threaded + iobound performance"
      echo -e "Subject: Performance Increase for Percona Server $PS_VERSION (tuned server settings + single threaded + iobound)\nBig increase in OLTP RW Run with tuned server settings + single threaded + iobound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_single_thread_iobound_res.txt 2>&1
    elif [ $RW_TS_IOBOUND_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP RW Run with tuned server settings + single threaded + iobound performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server $PS_VERSION (tuned server settings + single threaded + iobound)\nBig decrease in OLTP RW Run with tuned server settings + single threaded + iobound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_single_thread_iobound_res.txt 2>&1
    fi
    if [ $RW_TM_IOBOUND_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP RW Run with tuned server settings + multi threaded + iobound performance"
      echo -e "Subject: Performance Increase for Percona Server $PS_VERSION (tuned server settings + multi threaded + iobound)\nBig increase in OLTP RW Run with tuned server settings + multi threaded + iobound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_multi_thread_iobound_res.txt 2>&1
    elif [ $RW_TM_IOBOUND_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP RW Run with tuned server settings + multi threaded + iobound performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server $PS_VERSION (tuned server settings + multi threaded + iobound)\nBig decrease in OLTP RW Run with tuned server settings + multi threaded + iobound performance\n $LINK" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_tuned_rw_multi_thread_iobound_res.txt 2>&1
    fi
    echo "======================================================================="
  fi

  ## Save current results for next run's compare
  echo "$RW_DS_CPUBOUND_QUERIES" > $WORKSPACE/default_rw_ds_cpubound_lastrun.txt
  echo "$RW_DM_CPUBOUND_QUERIES" > $WORKSPACE/default_rw_dm_cpubound_lastrun.txt
  echo "$RW_TS_CPUBOUND_QUERIES" > $WORKSPACE/default_rw_ts_cpubound_lastrun.txt
  echo "$RW_TM_CPUBOUND_QUERIES" > $WORKSPACE/default_rw_tm_cpubound_lastrun.txt
  echo "$RW_TS_IOBOUND_QUERIES" > $WORKSPACE/default_rw_ts_iobound_lastrun.txt
  echo "$RW_TM_IOBOUND_QUERIES" > $WORKSPACE/default_rw_tm_iobound_lastrun.txt

  ## Permanent logging
  mv $WORKDIR/$WORKDIRSUB/sysbench_default_rw_single_thread_cpubound.txt $WORKSPACE/sysbench_default_rw_single_thread_cpubound_`date +"%F_%H%M"`.xml
  mv $WORKDIR/$WORKDIRSUB/sysbench_default_rw_multi_thread_cpubound.txt $WORKSPACE/sysbench_default_rw_multi_thread_cpubound_`date +"%F_%H%M"`.xml
  mv $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_single_thread_cpubound.txt $WORKSPACE/sysbench_tuned_rw_single_thread_cpubound_`date +"%F_%H%M"`.xml
  mv $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_multi_thread_cpubound.txt $WORKSPACE/sysbench_tuned_rw_multi_thread_cpubound_`date +"%F_%H%M"`.xml
  mv $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_single_thread_iobound.txt $WORKSPACE/sysbench_tuned_rw_single_thread_iobound_`date +"%F_%H%M"`.xml
  mv $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_multi_thread_iobound.txt $WORKSPACE/sysbench_tuned_rw_multi_thread_iobound_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_ds_cpu.xml $WORKSPACE/sysbench_performance_results_ds_cpu_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_dm_cpu.xml $WORKSPACE/sysbench_performance_results_dm_cpu_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_ts_cpu.xml $WORKSPACE/sysbench_performance_results_ts_cpu_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_tm_cpu.xml $WORKSPACE/sysbench_performance_results_tm_cpu_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_ts_io.xml $WORKSPACE/sysbench_performance_results_ts_io_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_tm_io.xml $WORKSPACE/sysbench_performance_results_tm_io_`date +"%F_%H%M"`.xml

  echo "`date +%F\t%k:%M`\tRW_DS_CPUBOUND:$RW_DS_CPUBOUND_QUERIES\tRW_DM_CPUBOUND:$RW_DM_CPUBOUND_QUERIES\tRW_TS_CPUBOUND:$RW_TS_CPUBOUND_QUERIES\tRW_TM_CPUBOUND:$RW_TM_CPUBOUND_QUERIES\tRW_TS_IOBOUND:$RW_TS_IOBOUND_QUERIES\tRW_TM_IOBOUND:$RW_TM_IOBOUND_QUERIES" >> $WORKSPACE/sysbench_performance_results_full_log.xml

fi

