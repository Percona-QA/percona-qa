#!/bin/bash

SYSBENCH_LOC="/usr/share/doc/sysbench/tests"
dbuser="root"
dbpass="root"
MYQ_GADGETS="/home/ramesh/pxc/myq_gadgets"
header="|%-10s |%-25s |%-25s |\n"

BASE="/usr"
DATADIR="/var/lib/mysql"
pxc_nodes=("208.88.225.243" "208.88.225.160")
pxc_gardb="208.88.225.240"

function verifyPXC {
 # Check PXC nodes are up
 for i in "${pxc_nodes[@]}"
 do
   check=`ssh $i "$BASE/bin/mysqladmin -uroot ping 2>/dev/null"`
   if [ -z "$check" ]; then
     echo "PXC is not running on $i"
     exit 1
   fi
 done
 echo "[Checked] : PXC nodes are running!"
}
function verifygarbd {
  # Check PXC garbd is running
  garbd_check=`ssh $pxc_gardb  pgrep "garbd"`
  if [ ! "$garbd_check" ]; then
   echo "garbd is not running on $pxc_gardb"
   exit 1
  fi
  echo "[Checked] : garbd is running!"
}


# Initiate sysbench run
verifyPXC
# Sysbench Prepare run
mysql -u$dbuser -h${pxc_nodes[0]} -e "drop database if exists pxc_test;create database pxc_test" 2>/dev/null
sysbench --test=$SYSBENCH_LOC/db/parallel_prepare.lua  --mysql-host=${pxc_nodes[0]}  --num-threads=10    --oltp-tables-count=10 --oltp-table-size=5000  --mysql-db=pxc_test --mysql-user=$dbuser  --db-driver=mysql run > sysbench_prepare.log

# Sysbench OLTP run
sysbench --test=$SYSBENCH_LOC/db/oltp.lua --mysql-host=${pxc_nodes[0]} --mysql-user=$dbuser   --mysql-password=$dbpass --num-threads=10    --oltp-tables-count=10 --mysql-db=pxc_test --oltp-table-size=50000 --report-interval=1 --max-requests=0 --tx-rate=100 run > /dev/null 2>&1 & 
SYSBENCH_PID="$!"

function checkPXC {
 wsrep_cluster_status=()
 wsrep_local_state_comment=()
 status_node1=`mysql -u $dbuser -h${pxc_nodes[0]} -Bse"show global status like 'wsrep_cluster_status'" 2>/dev/null | awk '{print $2}'`
 if [ -z $status_node1 ] ;  then   wsrep_cluster_status+=("MySQL_is_not_running!") ;  else wsrep_cluster_status+=($status_node1) ; fi
 status_node2=`mysql -u $dbuser -h${pxc_nodes[1]} -Bse"show global status like 'wsrep_cluster_status'" 2>/dev/null | awk '{print $2}'`
 if [ -z $status_node2 ] ;  then   wsrep_cluster_status+=("MySQL_is_not_running!") ;  else wsrep_cluster_status+=($status_node2) ; fi
 comment_node1=`mysql -u $dbuser -h${pxc_nodes[0]} -Bse"show global status like 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}'`
 if [ -z $comment_node1 ] ;  then wsrep_local_state_comment+=('MySQL_is_not_running!') ; else wsrep_local_state_comment+=($comment_node1) ; fi
 comment_node2=`mysql -u $dbuser -h${pxc_nodes[1]} -Bse"show global status like 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}'`
 if [ -z $comment_node2 ] ;  then wsrep_local_state_comment+=('MySQL_is_not_running!') ; else wsrep_local_state_comment+=($comment_node2) ; fi
 
 #printf '%s\n' "${wsrep_cluster_status[*]}"
 cluster_status=(${wsrep_cluster_status[@]})
 state_comment=(${wsrep_local_state_comment[@]})
}

function verifyPXC_start {
  ssh ${pxc_nodes[0]} "killall  mysqld  2>/dev/null" 
  ssh ${pxc_nodes[1]} "killall  mysqld  2>/dev/null" 
  sleep 10
  ssh ${pxc_nodes[0]} "rm -rf /var/lib/mysql/* ; $BASE/bin/mysql_install_db --basedir=$BASE --user=mysql --datadir=/var/lib/mysql > /dev/null 2>&1; $BASE/sbin/mysqld --basedir=$BASE --user=mysql --wsrep-new-cluster --skip-grant-tables  --log-error=/var/lib/mysql/error.log > /dev/null 2>&1 &"
  for X in $(seq 0 300); do
    sleep 1
    if ssh ${pxc_nodes[0]} "$BASE/bin/mysqladmin -uroot ping 2>/dev/null" ; then
      break 
    fi
  done
  ssh ${pxc_nodes[1]} "rm -rf /var/lib/mysql/* ; $BASE/bin/mysql_install_db --basedir=$BASE --user=mysql  > /dev/null 2>&1; $BASE/sbin/mysqld --basedir=$BASE --user=mysql --skip-grant-tables --wsrep_cluster_address=gcomm://${pxc_nodes[0]}  --wsrep_node_name=node2  --log-error=/var/lib/mysql/error.log > /dev/null 2>&1 &"
  
  for X in $(seq 0 300); do
    sleep 1
    if ssh ${pxc_nodes[1]} "$BASE/bin/mysqladmin -uroot ping 2>/dev/null" ; then
      break
    fi
  done 

}

rm -Rf garbd.log
function testReplwithgarbd {
#  verifyPXC_start
  verifygarbd
  checkPXC
  echo -e "PXC replication through garbd" >> garbd.log
  echo -e "----------------------------------------------------------------------\n"  >> garbd.log
  echo -e "Current PXC Status:\n" >> garbd.log
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> garbd.log
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> garbd.log

  #Kill PXC node to test garbd

  ssh ${pxc_nodes[1]} "pkill -9 -f mysqld  >/dev/null 2>&1;"
  echo -e "\nKilled mysqld from ${pxc_nodes[1]} for garbd testing\n" >> garbd.log
  checkPXC
  echo -e "PXC Status:\n" >> garbd.log
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> garbd.log
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> garbd.log
 # kill -9 ${SYSBENCH_PID} >/dev/null 2>&1
  pkill -9 -f sysbench >/dev/null 2>&1
}

function testReplwithoutgarbd {
  echo "PXC replication without garbd"
  ssh $pxc_gardb  "killall  garbd >/dev/null 2>&1;"
  verifyPXC_start

   # Sysbench OLTP run
  sysbench --test=$SYSBENCH_LOC/db/oltp.lua --mysql-host=${pxc_nodes[0]} --mysql-user=$dbuser   --mysql-password=$dbpass --num-threads=10    --oltp-tables-count=10 --mysql-db=pxc_test --oltp-table-size=50000 --report-interval=1 --max-requests=0 --tx-rate=100 run > /dev/null 2>&1 &
  SYSBENCH_PID="$!"
  sleep 2 
  checkPXC
  echo -e "\nPXC replication without garbd" >> garbd.log
  echo -e "---------------------------------------------------------------------\n"  >> garbd.log
  echo -e "Current PXC Status:\n" >> garbd.log
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> garbd.log
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> garbd.log

  #Kill PXC node to test garbd

  ssh ${pxc_nodes[1]} "pkill -9 -f mysqld" 2>/dev/null
  echo -e "\nKilled mysqld from ${pxc_nodes[1]} to check PXC node status (without garbd)\n" >> garbd.log
  sleep 10
  checkPXC
  echo -e "PXC Status:\n" >> garbd.log
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> garbd.log
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> garbd.log
  kill -9 ${SYSBENCH_PID} >/dev/null 2>&1;
}
testReplwithgarbd 
testReplwithoutgarbd

echo "Done! garbd result set log : ${PWD}/garbd.log"

