#!/bin/bash
# This script is for PXC Testing ChaosMonkey Style
# Please install PXC on your machine and execute this script from node1
# Analyze script_out.log file from workdir to get the PXC testcase output
# Also install following tools
# https://github.com/jayjanssen/myq_gadgets
# sysbench
IFS=$'\n'
WORKDIR="/ssd/pxc_test"
SCRIPT_PWD=$(cd `dirname $0` && pwd)
dbuser="test"
dbpass="test"
cd $WORKDIR
TSIZE=50000
TCOUNT=10
NUMT=10
header="|%-10s |%-25s |%-25s |\n"
rm -rf script_out.log before-node*.log

sysbench_run(){
  TEST_TYPE="$1"
  DB="$2"
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=$DB --mysql-user=$dbuser --mysql-password=$dbpass --mysql-host=$node1 --num-threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="--test=/usr/share/doc/sysbench/tests/db/oltp.lua --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --report-interval=1 --max-requests=0 --mysql-db=$DB --mysql-user=$dbuser --mysql-password=$dbpass --mysql-host=$i --num-threads=$NUMT --db-driver=mysql"
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if [ "$TEST_TYPE" == "load_data" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_insert.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=$dbuser --mysql-password=$dbpass --mysql-host=$node1 --threads=$NUMT --db-driver=mysql"
    elif [ "$TEST_TYPE" == "oltp" ];then
      SYSBENCH_OPTIONS="/usr/share/sysbench/oltp_read_write.lua --table-size=$TSIZE --tables=$TCOUNT --mysql-db=$DB --mysql-user=$dbuser --mysql-password=$dbpass --mysql-host=$i --threads=$NUMT --report-interval=1 --events=0 --db-driver=mysql"
    fi
  fi
}

#Change PXC Node IPs as per your configurations
nodes=("208.88.225.243" "208.88.225.240" "208.88.225.160")
node1="208.88.225.243"
node2="208.88.225.240"
node3="208.88.225.160"

function varifyPXC {
  #Checking PXC running status
  for i in "${nodes[@]}"
  do
    check=`ssh $i "/etc/init.d/mysql status"`
    status=`echo $check | awk '{print $1}'`
    if [ "$status" == "ERROR!" ] ; then
      echo "PXC is not running on $i"
      exit 1
    fi
  ssh $i "mkdir -p ${WORKDIR};cd ${WORKDIR};if [ -d percona-qa ]; then   cd percona-qa;   bzr pull; else   bzr branch lp:percona-qa; fi;"
  done
  # Sysbench Prepare run
  mysql -u$dbuser -p$dbpass -e "drop database if exists pxc_test;create database pxc_test"
  sysbench_run load_data pxc_test
  sysbench $SYSBENCH_OPTIONS prepare > sysbench_prepare.log

  for i in "${nodes[@]}"
  do
    echo $i
    sysbench_run oltp pxc_test
    sysbench $SYSBENCH_OPTIONS run | grep tps > /dev/null 2>&1 &
  done

  #Get monitoring state of each PXC node
  rm -rf node*.log after-node*.log
  myq_status -u $dbuser -p $dbpass -h $node1 -t 1 wsrep > node1.log &
  echo $! > myq_status_pid.txt
  myq_status -u $dbuser -p $dbpass -h $node2 -t 1 wsrep > node2.log &
  echo $! >> myq_status_pid.txt
  myq_status -u $dbuser -p $dbpass -h $node3 -t 1 wsrep > node3.log &
  echo $! >> myq_status_pid.txt
  sleep 120
  strt=`eval date +'%H:%M'`
  sleep 60
  stop=`eval date +'%H:%M'`

  sed -n "/$strt/ , /$stop/p" node1.log > before-node1.log
  sed -n "/$strt/ , /$stop/p" node2.log > before-node2.log
  sed -n "/$strt/ , /$stop/p" node3.log > before-node3.log
  bnode1_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024)}' before-node1.log`
  bnode2_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024)}' before-node2.log`
  bnode3_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024)}' before-node3.log`
  bnode1_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024)}' before-node1.log`
  bnode2_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024)}' before-node2.log`
  bnode3_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024)}' before-node3.log`

}
#check mysql status on PXC nodes

function checkPXC {
# IFS=$'\n'
 wsrep_cluster_status=()
 wsrep_local_state_comment=()
 status_node1=`mysql -u $dbuser -p$dbpass -h$node1 -Bse"show global status like 'wsrep_cluster_status'" | awk '{print $2}'`
 if [ -z $status_node1 ] ;  then   wsrep_cluster_status+=("MySQL is not running!") ;  else wsrep_cluster_status+=($status_node1) ; fi
 status_node2=`mysql -u $dbuser -p$dbpass -h$node2 -Bse"show global status like 'wsrep_cluster_status'" | awk '{print $2}'`
 if [ -z $status_node2 ] ;  then   wsrep_cluster_status+=("MySQL is not running!") ;  else wsrep_cluster_status+=($status_node2) ; fi
 status_node3=`mysql -u $dbuser -p$dbpass -h$node3 -Bse"show global status like 'wsrep_cluster_status'" | awk '{print $2}'`
 if [ -z $status_node3 ] ;  then   wsrep_cluster_status+=("MySQL is not running!") ;  else wsrep_cluster_status+=($status_node3) ; fi
 comment_node1=`mysql -u $dbuser -p$dbpass -h$node1 -Bse"show global status like 'wsrep_local_state_comment'" | awk '{print $2}'`
 if [ -z $comment_node1 ] ;  then wsrep_local_state_comment+=('MySQL is not running!') ; else wsrep_local_state_comment+=($comment_node1) ; fi
 comment_node2=`mysql -u $dbuser -p$dbpass -h$node2 -Bse"show global status like 'wsrep_local_state_comment'" | awk '{print $2}'`
 if [ -z $comment_node2 ] ;  then wsrep_local_state_comment+=('MySQL is not running!') ; else wsrep_local_state_comment+=($comment_node2) ; fi
 comment_node3=`mysql -u $dbuser -p$dbpass -h$node3 -Bse"show global status like 'wsrep_local_state_comment'" | awk '{print $2}'`
 if [ -z $comment_node3 ] ;  then wsrep_local_state_comment+=('MySQL is not running!') ; else wsrep_local_state_comment+=($comment_node3) ; fi
 #printf '%s\n' "${wsrep_cluster_status[*]}"
 cluster_status=(${wsrep_cluster_status[@]})
 state_comment=(${wsrep_local_state_comment[@]})
}

#Function for Network delay
function NWdelay {
  ms="$1ms"
  for i in "${nodes[@]}"
  do
    check=`ssh $i "/etc/init.d/mysql status"`
    node=`ssh $i "hostname"`
    status=`echo $check | awk '{print $1}'`
    if [ "$status" == "ERROR!" ] ; then
      ssh $i 'sudo rm -rf /var/lib/mysql/*.pid;sudo /etc/init.d/mysql start'
      sysbench_run oltp pxc_test
      sysbench $SYSBENCH_OPTIONS run | grep tps > /dev/null 2>&1 &
      rm -rf $node.log
      myq_status -u $dbuser -p $dbpass -h $i -t 1 wsrep > $node.log &
     echo $! >> myq_status_pid.txt
    fi
  done

  tc qdisc add dev eth1 root netem delay $ms
  sleep 120
  strt=`eval date +'%H:%M'`
  sleep 60
  stop=`eval date +'%H:%M'`

  sed -n "/$strt/ , /$stop/p" node1.log > after-node1.log
  sed -n "/$strt/ , /$stop/p" node2.log > after-node2.log
  sed -n "/$strt/ , /$stop/p" node3.log > after-node3.log

  node1_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024)}' after-node1.log`
  node2_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024)}' after-node2.log`
  node3_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024)}' after-node3.log`
  node1_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024)}' after-node1.log`
  node2_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024)}' after-node2.log`
  node3_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024)}' after-node3.log`

  echo -e "\n\n*************** Network Delay $1 milliseconds byte transfer rate b/w nodes ******************\n" >> script_out.log
  printf "|%-10s %-21s *%-20s |%-20s *%-20s |\n" "" "Normal" "" "NW delay($ms)" "" >> script_out.log
  echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
  header1="|%-10s |%-20s |%-20s |%-20s |%-20s |\n"
  printf "$header1" "Nodes" "Upload Rate(KB)" "Download Rate(KB)" "Upload Rate(KB)" "Download Rate(KB)" >> script_out.log
  echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
  printf "$header1" "Node 1" $bnode1_up $bnode1_dn $node1_up $node1_dn >> script_out.log
  printf "$header1" "Node 2" $bnode2_up $bnode2_dn $node2_up $node2_dn >> script_out.log
  printf "$header1" "Node 3" $bnode3_up $bnode3_dn $node3_up $node3_dn >> script_out.log
  checkPXC

  tc qdisc delete dev eth1 root
  echo -e "\n\n" >> script_out.log
  printf "$header" "Nodes" "wsrep_cluster_status" "wsrep_local_state" >> script_out.log
  echo -e "--------------------------------------------------------------------------" >> script_out.log
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> script_out.log
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> script_out.log
  printf "$header" "Node 3" ${cluster_status[2]} ${state_comment[2]} >> script_out.log
}

#Function for network packet loss
function NWpacketloss {
 for i in "${nodes[@]}"
 do
  check=`ssh $i "/etc/init.d/mysql status"`
  node=`ssh $i "hostname"`
  status=`echo $check | awk '{print $1}'`
  if [ "$status" == "ERROR!" ] ; then
   ssh $i 'sudo rm -rf /var/lib/mysql/*.pid;sudo /etc/init.d/mysql start'
   sysbench_run oltp pxc_test
   sysbench $SYSBENCH_OPTIONS  run | grep tps > /dev/null 2>&1 &
   rm -rf $node.log
   myq_status -u $dbuser -p $dbpass -h $i -t 1 wsrep > $node.log &
   echo $! >> myq_status_pid.txt
  fi
 done
 perc=$1

 tc qdisc add dev eth1 root netem loss $perc
 sleep 120
 strt=`eval date +'%H:%M'`
 sleep 60
 stop=`eval date +'%H:%M'`
 sed -n "/$strt/ , /$stop/p" node1.log > check-node1.log
 sed -n "/$strt/ , /$stop/p" node2.log > check-node2.log
 sed -n "/$strt/ , /$stop/p" node3.log > check-node3.log


 node1_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`
 node1_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`

 echo -e "\n\n********************************** Network packet loss $perc ***************************************\n" >> script_out.log
 printf "|%-10s %-21s *%-20s |%-20s *%-20s |\n" "" "Normal" "" "NW packet loss($perc)" "" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 header1="|%-10s |%-20s |%-20s |%-20s |%-20s |\n"
 printf "$header1" "Nodes" "Upload Rate(KB)" "Download Rate(KB)" "Upload Rate(KB)" "Download Rate(KB)" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 printf "$header1" "Node 1" $bnode1_up $bnode1_dn $node1_up $node1_dn >> script_out.log
 printf "$header1" "Node 2" $bnode2_up $bnode2_dn $node2_up $node2_dn >> script_out.log
 printf "$header1" "Node 3" $bnode3_up $bnode3_dn $node3_up $node3_dn >> script_out.log

 echo -e "\n\n" >> script_out.log
 checkPXC
 printf "$header" "Nodes" "wsrep_cluster_status" "wsrep_local_state" >> script_out.log
 echo -e "--------------------------------------------------------------------------" >> script_out.log
 printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> script_out.log
 printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> script_out.log
 printf "$header" "Node 3" ${cluster_status[2]} ${state_comment[2]} >> script_out.log

 tc qdisc delete dev eth1 root

}

#Function for network corruption
function NWpkt_corruption {
 for i in "${nodes[@]}"
 do
  check=`ssh $i "/etc/init.d/mysql status"`
  node=`ssh $i "hostname"`
  status=`echo $check | awk '{print $1}'`
  if [ "$status" == "ERROR!" ] ; then
   ssh $i 'sudo rm -rf /var/lib/mysql/*.pid;sudo /etc/init.d/mysql start'
   sysbench_run oltp pxc_test
   sysbench $SYSBENCH_OPTIONS run | grep tps > /dev/null 2>&1 &
   rm -rf $node.log
   myq_status -u $dbuser -p $dbpass -h $i -t 1 wsrep > $node.log &
   echo $! >> myq_status_pid.txt
  fi
 done
 perc=$1

 tc qdisc add dev eth1 root netem corrupt $perc
 sleep 120
 strt=`eval date +'%H:%M'`
 sleep 60
 stop=`eval date +'%H:%M'`
 sed -n "/$strt/ , /$stop/p" node1.log > check-node1.log
 sed -n "/$strt/ , /$stop/p" node2.log > check-node2.log
 sed -n "/$strt/ , /$stop/p" node3.log > check-node3.log


 node1_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`
 node1_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`

 echo -e "\n\n********************************** Network packet corruption $perc ***************************************\n" >> script_out.log
 printf "|%-10s %-21s *%-20s |%-20s *%-20s |\n" "" "Normal" "" "NW pkt corruption($perc)" "" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 header1="|%-10s |%-20s |%-20s |%-20s |%-20s |\n"
 printf "$header1" "Nodes" "Upload Rate(KB)" "Download Rate(KB)" "Upload Rate(KB)" "Download Rate(KB)" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 printf "$header1" "Node 1" $bnode1_up $bnode1_dn $node1_up $node1_dn >> script_out.log
 printf "$header1" "Node 2" $bnode2_up $bnode2_dn $node2_up $node2_dn >> script_out.log
 printf "$header1" "Node 3" $bnode3_up $bnode3_dn $node3_up $node3_dn >> script_out.log

 echo -e "\n\n" >> script_out.log

 checkPXC
 printf "$header" "Nodes" "wsrep_cluster_status" "wsrep_local_state" >> script_out.log
 echo -e "--------------------------------------------------------------------------" >> script_out.log
 printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> script_out.log
 printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> script_out.log
 printf "$header" "Node 3" ${cluster_status[2]} ${state_comment[2]} >> script_out.log

 tc qdisc delete dev eth1 root
}

# Function for network re-ordering
function NWpkt_reordering {
 for i in "${nodes[@]}"
 do
  check=`ssh $i "/etc/init.d/mysql status"`
  node=`ssh $i "hostname"`
  status=`echo $check | awk '{print $1}'`
  if [ "$status" == "ERROR!" ] ; then
   ssh $i 'sudo rm -rf /var/lib/mysql/*.pid;sudo /etc/init.d/mysql start'
   sysbench_run oltp pxc_test
   sysbench $SYSBENCH_OPTIONS run | grep tps > /dev/null 2>&1 &
   rm -rf $node.log
   myq_status -u $dbuser -p $dbpass -h $i -t 1 wsrep > $node.log &
   echo $! >> myq_status_pid.txt
  fi
 done
 perc1=$1
 perc2=$2
 tc qdisc add dev eth1 root netem delay 100ms $perc1 $perc2
 sleep 120
 strt=`eval date +'%H:%M'`
 sleep 60
 stop=`eval date +'%H:%M'`
 sed -n "/$strt/ , /$stop/p" node1.log > check-node1.log
 sed -n "/$strt/ , /$stop/p" node2.log > check-node2.log
 sed -n "/$strt/ , /$stop/p" node3.log > check-node3.log


 node1_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`
 node1_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`

 echo -e "\n\n********************** Network packet re-ordering (delay 100ms reorder $perc1 $perc2..) ******************\n" >> script_out.log
 printf "|%-10s %-21s *%-20s |%-20s *%-20s |\n" "" "Normal" "" "NW pkt re-ordering" "" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 header1="|%-10s |%-20s |%-20s |%-20s |%-20s |\n"
 printf "$header1" "Nodes" "Upload Rate(KB)" "Download Rate(KB)" "Upload Rate(KB)" "Download Rate(KB)" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 printf "$header1" "Node 1" $bnode1_up $bnode1_dn $node1_up $node1_dn >> script_out.log
 printf "$header1" "Node 2" $bnode2_up $bnode2_dn $node2_up $node2_dn >> script_out.log
 printf "$header1" "Node 3" $bnode3_up $bnode3_dn $node3_up $node3_dn >> script_out.log

 echo -e "\n\n" >> script_out.log
 checkPXC
 printf "$header" "Nodes" "wsrep_cluster_status" "wsrep_local_state" >> script_out.log
 echo -e "--------------------------------------------------------------------------" >> script_out.log
 printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> script_out.log
 printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> script_out.log
 printf "$header" "Node 3" ${cluster_status[2]} ${state_comment[2]} >> script_out.log

 tc qdisc delete dev eth1 root
}

#Function for single node failure
function singleNodefailure {
 for i in "${nodes[@]}"
 do
  check=`ssh $i "/etc/init.d/mysql status"`
  node=`ssh $i "hostname"`
  status=`echo $check | awk '{print $1}'`
  if [ "$status" == "ERROR!" ] ; then
   ssh $i 'sudo rm -rf /var/lib/mysql/*.pid;sudo /etc/init.d/mysql start'
   sysbench_run oltp pxc_test
   sysbench $SYSBENCH_OPTIONS run | grep tps > /dev/null 2>&1 &
   rm -rf $node.log
   myq_status -u $dbuser -p $dbpass -h $i -t 1 wsrep > $node.log &
   echo $! >> myq_status_pid.txt
  fi
 done
 ssh ${nodes[1]} '/etc/init.d/mysql stop'
 sleep 120
 strt=`eval date +'%H:%M'`
 sleep 60
 stop=`eval date +'%H:%M'`
 sed -n "/$strt/ , /$stop/p" node1.log > check-node1.log
 sed -n "/$strt/ , /$stop/p" node2.log > check-node2.log
 sed -n "/$strt/ , /$stop/p" node3.log > check-node3.log


 node1_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_up=`awk '{ if ( substr($11,length($11),1) == "K" )  sum += $11 * 1024 ;else if (substr($11,length($11),1) == "M")  sum += $11 * 1024 * 1024 ; else if ($11 ~ /[0-9]/) sum += $11 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`
 node1_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node1.log`
 node2_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node2.log`
 node3_dn=`awk '{ if ( substr($12,length($12),1) == "K" )  sum += $12 * 1024 ;else if (substr($12,length($12),1) == "M")  sum += $12 * 1024 * 1024 ; else if ($12 ~ /[0-9]/) sum += $12 fi } END {printf ("%0.2f\n",sum /1024/1024)}' check-node3.log`

 echo -e "\n\n****************************** PXC Single node failure status  *****************************************\n" >> script_out.log
 printf "|%-10s %-21s *%-20s |%-20s *%-20s |\n" "" "Normal" "" "NW pkt re-ordering" "" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 header1="|%-10s |%-20s |%-20s |%-20s |%-20s |\n"
 printf "$header1" "Nodes" "Upload Rate(KB)" "Download Rate(KB)" "Upload Rate(KB)" "Download Rate(KB)" >> script_out.log
 echo -e "----------------------------------------------------------------------------------------------------------" >> script_out.log
 printf "$header1" "Node 1" $bnode1_up $bnode1_dn $node1_up $node1_dn >> script_out.log
 printf "$header1" "Node 2" $bnode2_up $bnode2_dn $node2_up $node2_dn >> script_out.log
 printf "$header1" "Node 3" $bnode3_up $bnode3_dn $node3_up $node3_dn >> script_out.log

 echo -e "\n\n" >> script_out.log
 checkPXC
 printf "$header" "Nodes" "wsrep_cluster_status" "wsrep_local_state" >> script_out.log
 echo -e "--------------------------------------------------------------------------" >> script_out.log
 printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> script_out.log
 printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> script_out.log
 printf "$header" "Node 3" ${cluster_status[2]} ${state_comment[2]} >> script_out.log

}

function pxc269 {
 for i in "${nodes[@]}"
 do
  check=`ssh $i "/etc/init.d/mysql status"`
  node=`ssh $i "hostname"`
  status=`echo $check | awk '{print $1}'`
  if [ "$status" == "ERROR!" ] ; then
   ssh $i 'killall -9 mysqld mysqld_safe;sudo rm -rf /var/lib/mysql/*.pid;sudo /etc/init.d/mysql start'
   sysbench_run oltp pxc_test
   sysbench $SYSBENCH_OPTIONS run | grep tps > /dev/null 2>&1 &
   rm -rf $node.log
   myq_status -u $dbuser -p $dbpass -h $i -t 1 wsrep > $node.log &
   echo $! >> myq_status_pid.txt
  fi
 done
 ssh $node1 'killall -9 mysqld mysqld_safe; rm -rf /var/lib/mysql/mysql.pid; sleep 16;/etc/init.d/mysql start' > node1_statup.log 2>&1 &
 ssh $node2 'sleep 8; killall -9 mysqld mysqld_safe; rm -rf /var/lib/mysql/mysql.pid; sleep 24;/etc/init.d/mysql start' > node2_statup.log 2>&1 &
 ssh $node3 'sleep 16; killall -9 mysqld mysqld_safe; rm -rf /var/lib/mysql/mysql.pid; sleep 32;/etc/init.d/mysql start' > node3_statup.log 2>&1 &
 sleep 180
 echo -e "\n\n*************************************** PXC node failure status  *****************************************\n" >> script_out.log
 checkPXC
 ssh $node1 "cd ${WORKDIR};./percona-qa/pxc-hung-mysqld.sh"
 ssh $node2 "cd ${WORKDIR};./percona-qa/pxc-hung-mysqld.sh"
 ssh $node3 "cd ${WORKDIR};./percona-qa/pxc-hung-mysqld.sh"

 printf "$header" "Nodes" "wsrep_cluster_status" "wsrep_local_state" >> script_out.log
 echo -e "--------------------------------------------------------------------------" >> script_out.log
 printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} >> script_out.log
 printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} >> script_out.log
 printf "$header" "Node 3" ${cluster_status[2]} ${state_comment[2]} >> script_out.log

 echo -e "\nSaved GDB/coredump/error log in ${WORKDIR}"
}

function usage {
 echo "Usage: [ options ]"
 echo " Options:"
 echo "  ./pxc-failure-test.sh 1  ## Test : singleNodefailure"
 echo "  ./pxc-failure-test.sh 2  ## Test : PXC-269"
 echo "  ./pxc-failure-test.sh 3  ## Test : Network delay"
 echo "  ./pxc-failure-test.sh 4  ## Test : Network packet loss"
 echo "  ./pxc-failure-test.sh 5  ## Test : Network curruption"
 echo "  ./pxc-failure-test.sh 6  ## Test : Network reordering"
 echo "  ./pxc-failure-test.sh 0  ## Test all"

}
if [ "" == "$1" ]; then
 echo "Please choose any of these options:"
 usage
elif [ 1 == "$1" ]; then
 varifyPXC
 singleNodefailure
elif [ 2 == "$1" ]; then
 varifyPXC
 pxc269
elif [ 3 == "$1" ]; then
 varifyPXC
 NWdelay 1000
elif [ 4 == "$1" ]; then
 varifyPXC
 NWpacketloss 10%
elif [ 5 == "$1" ]; then
 varifyPXC
 NWpkt_corruption 5%
elif [ 6 == "$1" ]; then
 varifyPXC
 NWpkt_reordering 10% 25%
elif [ 0 == "$1" ]; then
 varifyPXC
 NWdelay 1000
 NWpacketloss 10%
 NWpkt_corruption 5%
 NWpkt_reordering 10% 25%
 singleNodefailure
 pxc269
else
 echo "Invalid option"
 usage
fi

kill -9 `cat myq_status_pid.txt` > /dev/null 2>&1
pkill sysbench  > /dev/null 2>&1

