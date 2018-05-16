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
  SYSBENCH_DURATION=900
fi

# Internal settings
MTR_BT=$[$RANDOM % 300 + 1]
PORT=$[20000 + $RANDOM % 9999 + 1]

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
  mkdir $WORKDIR/$WORKDIRSUB

  # Start server
  cd $WORKDIR/$BASEDIRSUB/mysql-test/
  set -o pipefail; MTR_BUILD_THREAD=$MTR_BT; perl lib/v1/mysql-test-run.pl \
    --start-and-exit \
    --skip-ndb \
    --vardir=$WORKDIR/$WORKDIRSUB \
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
    1st

  # Sysbench Runs
  ## Prepare/setup
  echo "Sysbench Run: Prepare stage"
  /usr/bin/sysbench --test=oltp --mysql-table-engine=innodb \
    --oltp-table-size=100000 --mysql-db=test --mysql-user=root \
    --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock prepare \
    > $WORKDIR/$WORKDIRSUB/sysbench_prepare.txt 2>&1
  ## OLTP RO Run
  echo "Sysbench Run: OLTP RO testing"
  /usr/bin/sysbench --num-threads=16 --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
    --test=oltp --oltp-table-size=100000 --mysql-db=test \
    --mysql-user=root --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
    --oltp-read-only run > $WORKDIR/$WORKDIRSUB/sysbench_ro_run.txt 2>&1
  ## OLTP RW Run
  echo "Sysbench Run: OLTP RW testing"
  /usr/bin/sysbench --num-threads=16 --max-time=$SYSBENCH_DURATION --max-requests=1870000000 \
    --test=oltp --oltp-table-size=100000 --mysql-db=test \
    --mysql-user=root --db-driver=mysql --mysql-socket=$WORKDIR/$WORKDIRSUB/socket.sock \
    run > $WORKDIR/$WORKDIRSUB/sysbench_rw_run.txt 2>&1

  # Process Results
  RO_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_ro_run.txt | awk '{print $2}' | xargs echo`
  RW_QUERIES=`grep "total:" $WORKDIR/$WORKDIRSUB/sysbench_rw_run.txt | awk '{print $2}' | xargs echo`

  ## Current run info to XML for Jenkins
  echo "Storing Sysbench results in $WORKSPACE"
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $WORKSPACE/sysbench_results.xml
  echo '<performance>' >> $WORKSPACE/sysbench_results.xml
  echo "  <READ_ONLY  type=\"result\">$RO_QUERIES</READ_ONLY>"  >> $WORKSPACE/sysbench_results.xml
  echo "  <READ_WRITE type=\"result\">$RW_QUERIES</READ_WRITE>" >> $WORKSPACE/sysbench_results.xml
  echo '</performance>' >> $WORKSPACE/sysbench_results.xml

  ## Compare against previous run
  if [ -r $WORKSPACE/sysbench_ro_lastrun.txt -a -r $WORKSPACE/sysbench_rw_lastrun.txt ]; then
    RO_QUERIES_LAST=`cat $WORKSPACE/sysbench_ro_lastrun.txt`
    RW_QUERIES_LAST=`cat $WORKSPACE/sysbench_rw_lastrun.txt`
    echo "======================================================================="
    echo "RO Last Run: $RO_QUERIES_LAST | RO This Run: $RO_QUERIES"
    echo "RW Last Run: $RW_QUERIES_LAST | RW This Run: $RW_QUERIES"
    echo "======================================================================="
    RO_FACTOR=`echo "scale=2; $RO_QUERIES / $RO_QUERIES_LAST" | bc`
    RW_FACTOR=`echo "scale=2; $RW_QUERIES / $RW_QUERIES_LAST" | bc`
    RO_PERCNT=`echo "$RO_FACTOR * 100" | bc | sed 's/\..*//'`
    RW_PERCNT=`echo "$RW_FACTOR * 100" | bc | sed 's/\..*//'`
    echo "RO Factor: $RO_FACTOR ($RO_PERCNT%)"
    echo "RW Factor: $RW_FACTOR ($RW_PERCNT%)"
    echo "======================================================================="
    if [ $RO_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP Read Only performance"
      echo -e "Subject: Performance Increase for Percona Server\nBig increase in OLTP Read Only performance" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_ro_res.txt 2>&1
    elif [ $RO_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP Read Only performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server\nBig decrease in OLTP Read Only performance" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_ro_res.txt 2>&1
    fi
    if [ $RW_PERCNT -ge 105 ]; then
      echo "Great: big increase in OLTP Read/Write performance"
      echo -e "Subject: Performance Increase for Percona Server\nBig increase in OLTP Read Write performance" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_ro_res.txt 2>&1
    elif [ $RW_PERCNT -le 95 ]; then
      echo "Warning: big decrease in OLTP Read/Write performance"
      echo -e "Subject: Performance Decrease Warning for Percona Server\nBig decrease in OLTP Read Write performance" \
        | $SENDMAIL -v -t ramesh.sivaraman@percona.com > $WORKSPACE/sendmail_ro_res.txt 2>&1
    fi
    echo "======================================================================="
  fi

  ## Save current results for next run's compare
  echo "$RO_QUERIES" > $WORKSPACE/sysbench_ro_lastrun.txt
  echo "$RW_QUERIES" > $WORKSPACE/sysbench_rw_lastrun.txt

  ## Permanent logging
  mv $WORKDIR/$WORKDIRSUB/sysbench_ro_run.txt $WORKSPACE/sysbench_results_ro_`date +"%F_%H%M"`.xml
  mv $WORKDIR/$WORKDIRSUB/sysbench_rw_run.txt $WORKSPACE/sysbench_results_rw_`date +"%F_%H%M"`.xml
  echo "`date +%F\t%k:%M`\tRO:$RO_QUERIES\tRW:$RW_QUERIES" >> $WORKSPACE/sysbench_results_full_log.xml

fi
