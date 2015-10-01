#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC
# This script will check PXC node status with Galera Arbitrator daemon (garbd).
# Prerequisites : sysbench 0.5, docker-compose
SYSBENCH_LOC="/usr/share/doc/sysbench/tests"
header="|%-10s |%-25s |%-25s |\n"
SCRIPT_PWD=$(cd `dirname $0` && pwd)

BASE="/usr"
DATADIR="/var/lib/mysql";
if [ ! `docker images | grep dockergarbd_bootstrap | awk '{print $1}'` ];then 
  echo "Docker image 'dockergarbd_bootstrap' is not present. please execute docker-compose up > /dev/null 2>&1 &"
  exit 1
elif [ `docker inspect --format '{{ .State.Running }}' dockergarbd_members_1` != "true" ];then
  echo "Docker container 'dockergarbd_members_1' is not running. please execute docker-compose up  > /dev/null 2>&1 &"
  exit 1
elif [ `docker inspect --format '{{ .State.Running }}' dockergarbd_bootstrap_1` != "true" ];then
  echo "Docker container 'dockergarbd_bootstrap_1' is not running. please execute docker-compose up  > /dev/null 2>&1 &"
  exit 1
elif [ `docker inspect --format '{{ .State.Running }}' dockergarbd_garbd_1` != "true" ];then
  echo "Docker container 'dockergarbd_garbd_1' is not running. please execute docker-compose up  > /dev/null 2>&1 &"
  exit 1
fi

pxc_nodes=("dockergarbd_bootstrap_1" "dockergarbd_members_1")
pxc_gardb="dockergarbd_garbd_1"

function verifyPXC {
 # Check PXC nodes are up
 for i in "${pxc_nodes[@]}"
 do
   check=`docker exec -it $i bash -c "/usr/bin/mysqladmin -uroot ping 2>/dev/null"`
   if [ -z "$check" ]; then
     echo "PXC is not running on $i"
     exit 1
   fi
 done
 echo "[Checked] : PXC nodes are running!"
}

function verifygarbd {
  # Check PXC garbd is running
  garbd_check=`docker exec -it $pxc_gardb bash -c "pgrep garbd"`
  if [ ! "$garbd_check" ]; then
    pxc_primary_ip=`docker inspect --format '{{ .NetworkSettings.IPAddress }}' ${pxc_nodes[0]}`
    docker exec -it $pxc_gardb bash -c "/galera/garb/garbd -a gcomm://$pxc_primary_ip:4567 -g pxc-garbd  -l /tmp/garbd.log -d" > /dev/null 2>&1
    sleep 10
    garbd_check=`docker exec -it $pxc_gardb bash -c "pgrep garbd"`
    if [ ! "$garbd_check" ]; then
      echo "garbd is not started. check $pxc_gardb container status"
      exit 1
    fi
  fi
  echo "[Checked] : garbd is running!"
}

verifyPXC
verifygarbd

# Sysbench Prepare run
mysql -uroot -h127.0.0.1 -P10000 -e "drop database if exists pxc_test;create database pxc_test" 2>/dev/null
sysbench --test=$SYSBENCH_LOC/db/parallel_prepare.lua  --mysql-host=127.0.0.1 --mysql-port=10000 --num-threads=10    --oltp-tables-count=10 --oltp-table-size=5000  --mysql-db=pxc_test --mysql-user=root  --db-driver=mysql run > sysbench_prepare.log

# Sysbench OLTP run
sysbench --test=$SYSBENCH_LOC/db/oltp.lua  --mysql-host=127.0.0.1 --mysql-port=10000 --mysql-user=root  --num-threads=10    --oltp-tables-count=10 --mysql-db=pxc_test --oltp-table-size=50000 --report-interval=1 --max-requests=0 --tx-rate=100 run > /dev/null 2>&1 & 
SYSBENCH_PID="$!"

function checkPXC {
 wsrep_cluster_status=()
 wsrep_local_state_comment=()
 status_node1=`mysql -u root -h127.0.0.1 -P10000 -Bse"show global status like 'wsrep_cluster_status'" 2>/dev/null | awk '{print $2}'`
 if [ -z $status_node1 ] ;  then   wsrep_cluster_status+=("MySQL_is_not_running!") ;  else wsrep_cluster_status+=($status_node1) ; fi
 status_node2=`mysql -u root -h127.0.0.1 -P11000 -Bse"show global status like 'wsrep_cluster_status'" 2>/dev/null | awk '{print $2}'`
 if [ -z $status_node2 ] ;  then   wsrep_cluster_status+=("MySQL_is_not_running!") ;  else wsrep_cluster_status+=($status_node2) ; fi
 comment_node1=`mysql -u root -h127.0.0.1 -P10000 -Bse"show global status like 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}'`
 if [ -z $comment_node1 ] ;  then wsrep_local_state_comment+=('MySQL_is_not_running!') ; else wsrep_local_state_comment+=($comment_node1) ; fi
 comment_node2=`mysql -u root -h127.0.0.1 -P11000 -Bse"show global status like 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}'`
 if [ -z $comment_node2 ] ;  then wsrep_local_state_comment+=('MySQL_is_not_running!') ; else wsrep_local_state_comment+=($comment_node2) ; fi
 
 #printf '%s\n' "${wsrep_cluster_status[*]}"
 cluster_status=(${wsrep_cluster_status[@]})
 state_comment=(${wsrep_local_state_comment[@]})
}

function restartPXCnodes {
 # Stop PXC nodes
 docker stop ${pxc_nodes[*]} > /dev/null 2>&1
 sleep 10
 cd $SCRIPT_PWD
 docker-compose up > /dev/null 2>&1 &
 sleep 30
 for i in "${pxc_nodes[@]}"
 do
   if [ `docker inspect --format '{{ .State.Running }}' $i` == "true" ];then
     check=`docker exec -it $i bash -c "/usr/bin/mysqladmin -uroot ping 2>/dev/null"`
     if [ -z "$check" ]; then
       echo "PXC is not running on $i"
       echo "Starting docker container $i"
       docker start $i > /dev/null 2>&1
       sleep 10
       check=`docker exec -it $i bash -c "/usr/bin/mysqladmin -uroot ping 2>/dev/null"`
       if [ -z "$check" ]; then
         echo "mysqld is not started. check $i container status"
         exit 1
       fi
     fi
   else
     echo "Docker container '$i' is not running. please docker container status"
     exit 1 
   fi
   
 done
}

function testReplwithgarbd {
  verifygarbd
  checkPXC
  echo -e "\nPXC replication through garbd" 
  echo -e "------------------------------------------------------------------\n"
  echo -e "Current PXC Status:\n" 
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]}
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]}

  #Kill PXC node to test garbd

  docker kill ${pxc_nodes[1]}  >/dev/null 2>&1;
  echo -e "\nKilled docker container ${pxc_nodes[1]} for garbd testing\n"
  checkPXC
  echo -e "PXC Status:\n" 
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]}
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]}
  kill ${SYSBENCH_PID} 
  wait ${SYSBENCH_PID} 2>/dev/null
}

function testReplwithoutgarbd {
  docker exec -it $pxc_gardb bash -c "pkill garbd" >/dev/null 2>&1;
  restartPXCnodes

  # Sysbench OLTP run
  sysbench --test=$SYSBENCH_LOC/db/oltp.lua --mysql-host=127.0.0.1 -P10000 --mysql-user=root  --num-threads=10    --oltp-tables-count=10 --mysql-db=pxc_test --oltp-table-size=50000 --report-interval=1 --max-requests=0 --tx-rate=100 run > /dev/null 2>&1 &
  SYSBENCH_PID="$!"
  sleep 2 
  checkPXC
  echo -e "\nPXC replication without garbd" 
  echo -e "-----------------------------------------------------------------\n"  
  echo -e "Current PXC Status:\n" 
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]} 
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]} 

  #Kill PXC node to test garbd

  docker kill ${pxc_nodes[1]}  >/dev/null 2>&1;
  echo -e "\nKilled docker container ${pxc_nodes[1]} to check PXC node status (without garbd)\n" 
  sleep 10
  checkPXC
  echo -e "PXC Status:\n"
  printf "$header" "Node 1" ${cluster_status[0]} ${state_comment[0]}
  printf "$header" "Node 2" ${cluster_status[1]} ${state_comment[1]}
  kill ${SYSBENCH_PID} >/dev/null 2>&1;
  wait ${SYSBENCH_PID} 2>/dev/null
}
testReplwithgarbd
testReplwithoutgarbd
