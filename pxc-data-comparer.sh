#!/bin/bash
# This script is for PXC Testing ChaosMonkey Style
# Please install PXC on your machine and execute this script from node1
# Also install following tools
# sysbench 0.5, percona-toolkit
IFS=$'\n'
WORKDIR="${PWD}"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
dbuser="root"
dbpass="root"
cd $WORKDIR
SYSBENCH_LOC="/usr/share/doc/sysbench/tests"
header="|%-10s |%-25s |%-25s |\n"
rm -rf $WORKDIR/sysbench_prepare.log

# Installing percona tookit
if ! rpm -qa | grep -qw percona-toolkit ; then 
  sudo yum install percona-toolkit
fi

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
 mysql -u$dbuser -p$dbpass -h${nodes[0]} -e "drop table if exists percona.dsns;create table percona.dsns(id int,parent_id int,dsn varchar(100));"
 for i in {0..2};do
   mysql -u$dbuser -p$dbpass -h${nodes[0]} -e "insert into percona.dsns (id,dsn) values ($i,'h=${nodes[$i]},P=3306,u=root,p=root');"
 done
 # Sysbench Prepare run 
 sysbench --test=$SYSBENCH_LOC/db/parallel_prepare.lua  --mysql-host=${nodes[0]}  --num-threads=10    --oltp-tables-count=10 --oltp-table-size=50000  --mysql-db=pxc_test --mysql-user=$dbuser --mysql-password=$dbpass   --db-driver=mysql run > $WORKDIR/sysbench_prepare.log
 
}
verifyPXC
for i in {1..5}; do
  # Sysbench transaction run
  sysbench --test=$SYSBENCH_LOC/db/oltp.lua --mysql-host=${nodes[0]} --mysql-user=$dbuser   --mysql-password=$dbpass --num-threads=10    --oltp-tables-count=10 --mysql-db=pxc_test --oltp-table-size=50000 --max-time=300 --report-interval=1 --max-requests=0 --tx-rate=100 run | grep tps > /dev/null 2>&1
  # Run pt-table-checksum to analyze data consistency 
  pt-table-checksum h=208.88.225.243,P=3306,u=root,p=root -d pxc_test --recursion-method dsn=h=208.88.225.243,P=3306,u=root,p=root,D=percona,t=dsns
done
