#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

# User settings
MAIL="/bin/mail"
if [ -z "${WORKDIR}" ]; then
  WORKDIR=/data/bench/perf
fi

# Internal settings
DATADIR_TEMPLATE=/data/bench/perf
SYSBENCH_DURATION=300
MTR_BT=$[$RANDOM % 300 + 1]
PORT=$[20000 + $RANDOM % 9999 + 1]
MULTI_THREAD_COUNT=400
THREAD_CNT=2048
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

echo "Workdir: $WORKDIR/$WORKDIRSUB"
echo "Basedir: $WORKDIR/$BASEDIRSUB"

# Check directories & start run if all ok
if [  -d $WORKDIR/$WORKDIRSUB ]; then
  echo "Work directory already exists. Fatal error.";
  exit 1
elif [ ! -d $WORKDIR/$BASEDIRSUB ]; then
  echo "Base directory does not exist. Fatal error.";
  exit 1
else
  BASEDIR="$WORKDIR/$BASEDIRSUB"
  if [ -r ${BASEDIR}/bin/mysqld ]; then
    BIN=${BASEDIR}/bin/mysqld
  else
    # Check if this is a debug build by checking if debug string is present in dirname
    if [[ ${BASEDIR} = *debug* ]]; then
      if [ -r ${BASEDIR}/bin/mysqld-debug ]; then
        BIN=${BASEDIR}/bin/mysqld-debug
      else
        echoit "Assert: there is no (script readable) mysqld binary at ${BASEDIR}/bin/mysqld[-debug] ?"
        exit 1
      fi
    else
      echoit "Assert: there is no (script readable) mysqld binary at ${BASEDIR}/bin/mysqld ?"
      exit 1
    fi
  fi
  PS_VERSION=`$BASEDIR/bin/mysqld --version | awk '{print $3}' | cut -c1-3`
  if [ $PS_VERSION == "5.6" ];then
    if [ -d $DATADIR_TEMPLATE/56_data_template/master-data -a -d $DATADIR_TEMPLATE/56_tuned_data_template/master-data ];then
      mkdir -p $WORKDIR/$WORKDIRSUB/default_datadir $WORKDIR/$WORKDIRSUB/tuned_datadir
      cp -R $DATADIR_TEMPLATE/56_data_template/master-data/* $WORKDIR/$WORKDIRSUB/default_datadir/
      cp -R $DATADIR_TEMPLATE/56_tuned_data_template/master-data/* $WORKDIR/$WORKDIRSUB/tuned_datadir/
      sleep 5
      IO_TUNED_VAR="--loose-innodb_lazy_drop_table=1 --innodb-old-blocks_time=0 --innodb-buffer-pool-size=1G --innodb-lru-scan-depth=3000 --innodb-log-file-size=1G --innodb-io-capacity=2000 --innodb-io-capacity-max=4000 --innodb-flush-log-at-trx-commit=1 --innodb-flush-method=O_DIRECT --innodb-checksum-algorithm=crc32 --innodb-log-checksum-algorithm=crc32"
      CPU_TUNED_VAR="--loose-innodb_lazy_drop_table=1 --innodb-old-blocks_time=0 --innodb-buffer-pool-size=5G --innodb-lru-scan-depth=3000 --innodb-log-file-size=1G --innodb-io-capacity=2000 --innodb-io-capacity-max=4000 --innodb-flush-log-at-trx-commit=1 --innodb-flush-method=O_DIRECT --innodb-checksum-algorithm=crc32 --innodb-log-checksum-algorithm=crc32"
    else
      echo "Data directory template does not exist. Fatal error.";
      exit 1
    fi
  elif [ $PS_VERSION == "5.7" ];then
    if [ -d $DATADIR_TEMPLATE/57_data_template/master-data -a -d $DATADIR_TEMPLATE/57_tuned_data_template/master-data ];then
      mkdir -p $WORKDIR/$WORKDIRSUB/default_datadir $WORKDIR/$WORKDIRSUB/tuned_datadir
      cp -R $DATADIR_TEMPLATE/57_data_template/master-data/* $WORKDIR/$WORKDIRSUB/default_datadir/
      cp -R $DATADIR_TEMPLATE/57_tuned_data_template/master-data/* $WORKDIR/$WORKDIRSUB/tuned_datadir/
      sleep 5
      IO_TUNED_VAR="--loose-innodb_lazy_drop_table=1 --innodb-old-blocks_time=0 --innodb-buffer-pool-size=1G --innodb-log-file-size=1G --innodb-io-capacity=2000 --innodb-flush-log-at-trx-commit=1 --innodb-flush-method=O_DIRECT --innodb-buffer-pool-instances=8"
      CPU_TUNED_VAR="--loose-innodb_lazy_drop_table=1 --innodb-old-blocks_time=0 --innodb-buffer-pool-size=5G --innodb-log-file-size=1G --innodb-io-capacity=2000 --innodb-flush-log-at-trx-commit=1 --innodb-flush-method=O_DIRECT --innodb-buffer-pool-instances=8"
    else
      echo "Data directory template does not exist. Fatal error.";
      exit 1
    fi
  elif [ $PS_VERSION == "5.5" ];then
    if [ -d $DATADIR_TEMPLATE/55_data_template/master-data -a -d $DATADIR_TEMPLATE/55_tuned_data_template/master-data ];then
      mkdir -p $WORKDIR/$WORKDIRSUB/default_datadir $WORKDIR/$WORKDIRSUB/tuned_datadir
      cp -R $DATADIR_TEMPLATE/55_data_template/master-data/* $WORKDIR/$WORKDIRSUB/default_datadir/
      cp -R $DATADIR_TEMPLATE/55_tuned_data_template/master-data/* $WORKDIR/$WORKDIRSUB/tuned_datadir/
      sleep 5
      IO_TUNED_VAR="--loose-innodb_lazy_drop_table=1 --innodb-old-blocks_time=0 --innodb-buffer-pool-size=1G --innodb-log-file-size=1G --innodb-io-capacity=2000 --innodb-flush-log-at-trx-commit=1 --innodb-flush-method=O_DIRECT --innodb-buffer-pool-instances=8"
      CPU_TUNED_VAR="--loose-innodb_lazy_drop_table=1 --innodb-old-blocks_time=0 --innodb-buffer-pool-size=5G --innodb-log-file-size=1G --innodb-io-capacity=2000 --innodb-flush-log-at-trx-commit=1 --innodb-flush-method=O_DIRECT --innodb-buffer-pool-instances=8"
    else
      echo "Data directory template does not exist. Fatal error.";
      exit 1
    fi
  else
   echo "Script is created only for PS version 5.5 and 5.6. Retry.."
   exit 1
  fi
  # Start the server with default server settings.
  $BIN --basedir=${BASEDIR} --datadir=$WORKDIR/$WORKDIRSUB/default_datadir --tmpdir=$WORKDIR/$WORKDIRSUB/default_datadir \
	--core-file --port=$PORT --pid_file=$WORKDIR/$WORKDIRSUB/default_datadir/pid.pid --socket=$WORKDIR/$WORKDIRSUB/socket.sock \
	--log-output=none --log-error=$WORKDIR/$WORKDIRSUB/default_datadir/master.err --max-connections=3000 > $WORKDIR/$WORKDIRSUB/default_datadir/startup.err 2>&1 &
  for X in $(seq 0 60); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/$WORKDIRSUB/socket.sock ping > /dev/null 2>&1; then
      break
    fi
  done
  # Sysbench Runs
  ## OLTP RO Run for memory Warmup
  echo "Sysbench Run: OLTP RO Run for memory Warmup"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=300 --max-requests=1870000000 \
   --oltp-tables-count=15 --mysql-db=test --oltp-read-only --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_ro_run_warm_up.txt 2>&1
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_dcpu.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_dcpu.xml
  i=1
  rm -Rf $WORKSPACE/sysbench_performance_results_dcpu.txt
  while [ $i -le $THREAD_CNT ]; do
    for j in $(seq 1 2); do
      ## OLTP RW Run with default server settings + cpubound ( data size approx = 6G)
      echo "Sysbench Run: OLTP RW testing with default server settings + cpubound ( data size approx = 6G)"
      /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
        --num-threads=$i --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
        --oltp-tables-count=5 --mysql-db=test --mysql-user=root \
        --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
        run > $WORKDIR/$WORKDIRSUB/sysbench_default_rw_${j}_thread_cpubound_run.txt 2>&1
    done
    FIRST_RESULT=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_default_rw_1_thread_cpubound_run.txt | awk '{print $2}' | xargs echo`
    SECOND_RESULT=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_default_rw_2_thread_cpubound_run.txt | awk '{print $2}' | xargs echo`
    AVG_RESULT=$(( (FIRST_RESULT + SECOND_RESULT) / 2 ))
    echo "  <THREAD_${i} type=\"result\">$AVG_RESULT</THREAD_${i}>" >> $WORKSPACE/sysbench_performance_results_dcpu.xml
    echo "THREAD_${i} $AVG_RESULT" >> $WORKSPACE/sysbench_performance_results_dcpu.txt
    i=$(( i * 2))
  done
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_dcpu.xml
  ## Cleanup system
  timeout --signal=9 20s ${BASEDIR}/bin/mysqladmin --socket=$WORKDIR/$WORKDIRSUB/socket.sock -uroot shutdown /dev/null 2>&1
  $BIN $IO_TUNED_VAR --basedir=${BASEDIR} --datadir=$WORKDIR/$WORKDIRSUB/tuned_datadir --tmpdir=$WORKDIR/$WORKDIRSUB/tuned_datadir \
        --core-file --port=$PORT --pid_file=$WORKDIR/$WORKDIRSUB/tuned_datadir/pid.pid --socket=$WORKDIR/$WORKDIRSUB/socket.sock \
        --log-output=none --log-error=$WORKDIR/$WORKDIRSUB/tuned_datadir/master.err  --max-connections=3000 > $WORKDIR/$WORKDIRSUB/tuned_datadir/startup.err 2>&1 &
  for X in $(seq 0 60); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/$WORKDIRSUB/socket.sock ping > /dev/null 2>&1; then
      break
    fi
  done
  ## OLTP RO Run for memory Warmup
  echo "Sysbench Run: OLTP RO Run for memory Warmup"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=300 --max-requests=1870000000 \
   --oltp-tables-count=15 --mysql-db=test --oltp-read-only --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_ro_run_warm_up.txt 2>&1
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_tio.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_tio.xml
  i=1
  rm -Rf $WORKSPACE/sysbench_performance_results_tio.txt
  while [ $i -le $THREAD_CNT ]; do
    for j in $(seq 1 2); do
      ## OLTP RW Run with tuned server settings + iobound ( data size approx = 6G)
      echo "Sysbench Run: OLTP RW Run with tuned server settings + iobound ( data size approx = 6G)"
      /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
       --num-threads=$i --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
       --oltp-tables-count=5 --mysql-db=test --mysql-user=root \
       --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
       run > $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_${j}_thread_iobound.txt 2>&1
    done
    FIRST_RESULT=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_1_thread_iobound.txt | awk '{print $2}' | xargs echo`
    SECOND_RESULT=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_2_thread_iobound.txt | awk '{print $2}' | xargs echo`
    AVG_RESULT=$(( (FIRST_RESULT + SECOND_RESULT) / 2 ))
    echo "  <THREAD_${i} type=\"result\">$AVG_RESULT</THREAD_${i}>" >> $WORKSPACE/sysbench_performance_results_tio.xml
    echo "THREAD_${i} $AVG_RESULT" >> $WORKSPACE/sysbench_performance_results_tio.txt
    i=$(( i * 2))
  done
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_tio.xml
  ## Cleanup system
  timeout --signal=9 20s ${BASEDIR}/bin/mysqladmin --socket=$WORKDIR/$WORKDIRSUB/socket.sock -uroot shutdown /dev/null 2>&1

  $BIN $CPU_TUNED_VAR --basedir=${BASEDIR} --datadir=$WORKDIR/$WORKDIRSUB/tuned_datadir --tmpdir=$WORKDIR/$WORKDIRSUB/tuned_datadir \
        --core-file --port=$PORT --pid_file=$WORKDIR/$WORKDIRSUB/tuned_datadir/pid.pid --socket=$WORKDIR/$WORKDIRSUB/socket.sock \
        --log-output=none --log-error=$WORKDIR/$WORKDIRSUB/tuned_datadir/master.err  --max-connections=3000 > $WORKDIR/$WORKDIRSUB/tuned_datadir/startup.err 2>&1 &
  for X in $(seq 0 60); do
    sleep 1
    if ${BASEDIR}/bin/mysqladmin -uroot -S$WORKDIR/$WORKDIRSUB/socket.sock ping > /dev/null 2>&1; then
      break
    fi
  done
  ## OLTP RO Run for memory Warmup
  echo "Sysbench Run: OLTP RO Run for memory Warmup"
  /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
   --num-threads=$MULTI_THREAD_COUNT --max-time=300 --max-requests=1870000000 \
   --oltp-tables-count=15 --mysql-db=test --oltp-read-only --mysql-user=root \
   --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
   run > $WORKDIR/$WORKDIRSUB/sysbench_ro_run_warm_up.txt 2>&1
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_performance_results_tcpu.xml
  echo '<performance>' >> $WORKSPACE/sysbench_performance_results_tcpu.xml
  i=1
  $WORKSPACE/sysbench_performance_results_tcpu.txt
  while [ $i -le $THREAD_CNT ]; do
    for j in $(seq 1 2); do
      ## OLTP RW Run with tuned server settings + cpubound ( data size approx = 6G)
      echo "Sysbench Run: OLTP RW testing with tuned server settings + cpubound ( data size approx = 6G)"
      /usr/bin/sysbench --test=/usr/share/doc/sysbench/tests/db/oltp.lua \
       --num-threads=$i --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
       --oltp-tables-count=5 --mysql-db=test --mysql-user=root --db-driver=mysql \
       --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
       run > $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_${j}_thread_cpubound.txt 2>&1
    done
    FIRST_RESULT=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_1_thread_cpubound.txt | awk '{print $2}' | xargs echo`
    SECOND_RESULT=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_tuned_rw_2_thread_cpubound.txt | awk '{print $2}' | xargs echo`
    AVG_RESULT=$(( (FIRST_RESULT + SECOND_RESULT) / 2 ))
    echo "  <THREAD_${i} type=\"result\">$AVG_RESULT</THREAD_${i}>" >> $WORKSPACE/sysbench_performance_results_tcpu.xml
    echo "THREAD_${i} $AVG_RESULT" >> $WORKSPACE/sysbench_performance_results_tcpu.txt
    i=$(( i * 2))
  done
  echo '</performance>' >> $WORKSPACE/sysbench_performance_results_tcpu.xml
  ## Cleanup system
  timeout --signal=9 20s ${BASEDIR}/bin/mysqladmin --socket=$WORKDIR/$WORKDIRSUB/socket.sock -uroot shutdown /dev/null 2>&1

  ## Compare against previous run
  if [ -r $WORKSPACE/sysbench_performance_results_dcpu_lastrun.txt -a -r $WORKSPACE/sysbench_performance_results_tio_lastrun.txt -a -r $WORKSPACE/sysbench_performance_results_tcpu_lastrun.txt ]; then
    echo "================== DEFAULT CPUBOUND PERFORMANCE RESULT ====================="
    rm -Rf $WORKSPACE/increase_msg.txt
    rm -Rf $WORKSPACE/decrease_msg.txt
    while read line ; do
      THREADS=`echo $line |awk '{print $1}'`
      AVG_RUN=`echo $line |awk '{print $2}'`
      AVG_RUN_LAST=`grep $THREADS $WORKSPACE/sysbench_performance_results_dcpu_lastrun.txt |awk '{print $2}'`
      THREADS_FACTOR=`echo "scale=2; $AVG_RUN / $AVG_RUN_LAST" | bc`
      THREADS_PERCNT=`echo "$THREADS_FACTOR * 100" | bc | sed 's/\..*//'`
      echo "RW_DEFAULT_CPUBOUND_${THREADS}: $THREADS_FACTOR ($THREADS_PERCNT%)"
      if [ "$THREADS_PERCNT" -ge 105 ];then
        echo "Great: big increase in OLTP RW Run with default server settings + ${THREADS} + cpubound performance" >> $WORKSPACE/increase_msg.txt
      elif [ "$THREADS_PERCNT" -le 95 ]; then
        echo "Warning: big decrease in OLTP RW Run with default server settings + ${THREADS} + cpubound performance" >> $WORKSPACE/decrease_msg.txt
      fi
    done < $WORKSPACE/sysbench_performance_results_dcpu.txt
    if [ -s $WORKSPACE/increase_msg.txt ];then
      $MAIL -s "Performance Increase for Percona Server $PS_VERSION (default server settings + cpubound)"  ramesh.sivaraman@percona.com < $WORKSPACE/increase_msg.txt > $WORKSPACE/mail_default_cpubound_res.txt 2>&1
    elif [ -s $WORKSPACE/decrease_msg.txt ];then
      $MAIL -s "Performance Decrease Warning for Percona Server $PS_VERSION (default server settings  + cpubound)" ramesh.sivaraman@percona.com < $WORKSPACE/decrease_msg.txt > $WORKSPACE/mail_default_cpubound_res.txt 2>&1
    fi
    echo "============================================================================"
    echo "=================== TUNED CPUBOUND PERFORMANCE RESULT ======================"
    rm -Rf $WORKSPACE/increase_msg.txt
    rm -Rf $WORKSPACE/decrease_msg.txt
    while read line ; do
      THREADS=`echo $line |awk '{print $1}'`
      AVG_RUN=`echo $line |awk '{print $2}'`
      AVG_RUN_LAST=`grep $THREADS $WORKSPACE/sysbench_performance_results_tcpu_lastrun.txt |awk '{print $2}'`
      THREADS_FACTOR=`echo "scale=2; $AVG_RUN / $AVG_RUN_LAST" | bc`
      THREADS_PERCNT=`echo "$THREADS_FACTOR * 100" | bc | sed 's/\..*//'`
      echo "RW_DEFAULT_CPUBOUND_${THREADS}: $THREADS_FACTOR ($THREADS_PERCNT%)"
      if [ "$THREADS_PERCNT" -ge 105 ];then
        echo "Great: big increase in OLTP RW Run with tuned server settings + ${THREADS} + cpubound performance" >> $WORKSPACE/increase_msg.txt
      elif [ "$THREADS_PERCNT" -le 95 ]; then
        echo "Warning: big decrease in OLTP RW Run with tuned server settings + ${THREADS} + cpubound performance" >> $WORKSPACE/decrease_msg.txt
      fi
    done < $WORKSPACE/sysbench_performance_results_tcpu.txt
    if [ -s $WORKSPACE/increase_msg.txt ];then
      $MAIL -s "Performance Increase for Percona Server $PS_VERSION (tuned server settings + cpubound)"  ramesh.sivaraman@percona.com < $WORKSPACE/increase_msg.txt > $WORKSPACE/mail_tuned_cpubound_res.txt 2>&1
    elif [ -s $WORKSPACE/decrease_msg.txt ];then
      $MAIL -s "Performance Decrease Warning for Percona Server $PS_VERSION (tuned server settings  + cpubound)" ramesh.sivaraman@percona.com < $WORKSPACE/decrease_msg.txt > $WORKSPACE/mail_tuned_cpubound_res.txt 2>&1
    fi
    echo "============================================================================"
    echo "==================== TUNED IOBOUND PERFORMANCE RESULT ======================"
    rm -Rf $WORKSPACE/increase_msg.txt
    rm -Rf $WORKSPACE/decrease_msg.txt
    while read line ; do
      THREADS=`echo $line |awk '{print $1}'`
      AVG_RUN=`echo $line |awk '{print $2}'`
      AVG_RUN_LAST=`grep $THREADS $WORKSPACE/sysbench_performance_results_tio_lastrun.txt |awk '{print $2}'`
      THREADS_FACTOR=`echo "scale=2; $AVG_RUN / $AVG_RUN_LAST" | bc`
      THREADS_PERCNT=`echo "$THREADS_FACTOR * 100" | bc | sed 's/\..*//'`
      echo "RW_DEFAULT_CPUBOUND_${THREADS}: $THREADS_FACTOR ($THREADS_PERCNT%)"
      if [ "$THREADS_PERCNT" -ge 105 ];then
        echo "Great: big increase in OLTP RW Run with tuned server settings + ${THREADS} + iobound performance" >> $WORKSPACE/increase_msg.txt
      elif [ "$THREADS_PERCNT" -le 95 ]; then
        echo "Warning: big decrease in OLTP RW Run with tuned server settings + ${THREADS} + iobound performance" >> $WORKSPACE/decrease_msg.txt
      fi
    done < $WORKSPACE/sysbench_performance_results_tio.txt
    if [ -s $WORKSPACE/increase_msg.txt ];then
      $MAIL -s "Performance Increase for Percona Server $PS_VERSION (tuned server settings + iobound)"  ramesh.sivaraman@percona.com < $WORKSPACE/increase_msg.txt > $WORKSPACE/mail_tuned_iobound_res.txt 2>&1
    elif [ -s $WORKSPACE/decrease_msg.txt ];then
      $MAIL -s "Performance Decrease Warning for Percona Server $PS_VERSION (tuned server settings  + iobound)" ramesh.sivaraman@percona.com < $WORKSPACE/decrease_msg.txt > $WORKSPACE/mail_tuned_iobound_res.txt 2>&1
    fi
    echo "============================================================================"
  fi
  ## Save current results for next run's compare
  cp $WORKSPACE/sysbench_performance_results_dcpu.txt $WORKSPACE/sysbench_performance_results_dcpu_lastrun.txt
  cp $WORKSPACE/sysbench_performance_results_tio.txt $WORKSPACE/sysbench_performance_results_tio_lastrun.txt
  cp $WORKSPACE/sysbench_performance_results_tcpu.txt $WORKSPACE/sysbench_performance_results_tcpu_lastrun.txt
  ## Permanent logging
  cp $WORKSPACE/sysbench_performance_results_dcpu.xml $WORKSPACE/sysbench_performance_results_dcpu_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_tcpu.xml $WORKSPACE/sysbench_performance_results_tcpu_`date +"%F_%H%M"`.xml
  cp $WORKSPACE/sysbench_performance_results_tio.xml  $WORKSPACE/sysbench_performance_results_tio_`date +"%F_%H%M"`.xml
fi
