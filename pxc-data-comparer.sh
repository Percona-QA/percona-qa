#!/bin/bash
# Please install PXC on your machine and execute this script from node1
# Also install following tools
# sysbench, percona-toolkit
IFS=$'\n'
WORKDIR="${PWD}"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
dbuser="root"
dbpass="root"
cd $WORKDIR
SYSBENCH_LOC="/usr/share/doc/sysbench/tests"
header="|%-10s |%-25s |%-25s |\n"
rm -rf $WORKDIR/sysbench_prepare.log

TSIZE=50000
TCOUNT=10
NUMT=10
SDURATION=300

# Installing percona tookit
if ! rpm -qa | grep -qw percona-toolkit ; then 
  sudo yum install percona-toolkit
fi

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --max-time=$SDURATION --report-interval=1 --max-requests=1870000000 --mysql-db=$DB --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --threads=$NUMT --time=$SDURATION --report-interval=1 --events=1870000000 --db-driver=mysql"
    fi
  fi
}

#Change PXC Node IPs as per your configurations

nodes=("208.88.225.243" "208.88.225.240" "208.88.225.160")

function verifyPXC {
  #Checking PXC running status
  for i in "${nodes[@]}"
  do
    check=`ssh $i "/etc/init.d/mysql.server status"`
    status=`echo $check | awk '{print $1}'`
    if [ $status == "ERROR!" ] ; then
      echo "PXC is not running on $i"
      exit 1
    fi
  done
  mysql -u$dbuser -p$dbpass -h${nodes[0]} -e "drop database if exists pxc_test;create database pxc_test;drop database if exists percona;create database percona;"
  # Create DSNs table to run pt-table-checksum
  mysql -u$dbuser -p$dbpass -h${nodes[0]} -e "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100), primary key(id));"
  for i in {0..2};do
    mysql -u$dbuser -p$dbpass -h${nodes[0]} -e "insert into percona.dsns (id,dsn) values ($i,'h=${nodes[$i]},P=3306,u=root,p=root');"
  done
  # Sysbench Prepare run
  sysbench_run load_data pxc_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=$dbuser --mysql-password=$dbpass --mysql-host=${nodes[0]} run > $WORKDIR/sysbench_prepare.log
}
verifyPXC
for i in {1..5}; do
  # Sysbench transaction run
  sysbench_run oltp pxc_test
  $SBENCH $SYSBENCH_OPTIONS --mysql-user=$dbuser --mysql-password=$dbpass --mysql-host=${nodes[0]}  run | grep tps > /dev/null 2>&1
  # Run pt-table-checksum to analyze data consistency 
  pt-table-checksum h=208.88.225.243,P=3306,u=root,p=root -d pxc_test --recursion-method dsn=h=208.88.225.243,P=3306,u=root,p=root,D=percona,t=dsns
done
