#!/bin/bash
# Created by Ramesh Sivaraman, Percona LLC

# Dispay script usage details
usage () {
  echo "Usage:"
  echo ""
  echo "bash pxc-startup.sh"
  echo ""
  echo " This script will help you configure multi node"
  echo " PXC cluster using binary tarball on your local machine"
  echo ""
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=h --longoptions=help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- "$go_out"
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -h | --help )
      usage
      exit 0
      ;;
    ?)
      echo "Invalid option: ${OPTARG}"
      ;;
  esac
done


BUILD=$(pwd)
SKIP_RQG_AND_BUILD_EXTRACT=0
sst_method="xtrabackup-v2"
ADD_SYSBENCH_SCRIPTS=0

#Format version string (thanks to wsrep_sst_xtrabackup-v2) 
normalize_version(){
  local major=0
  local minor=0
  local patch=0
  
  # Only parses purely numeric version numbers, 1.2.3
  # Everything after the first three values are ignored
  if [[ $1 =~ ^([0-9]+)\.([0-9]+)\.?([0-9]*)([\.0-9])*$ ]]; then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    patch=${BASH_REMATCH[3]}
  fi
  printf %02d%02d%02d $major $minor $patch
}

#Version comparison script (thanks to wsrep_sst_xtrabackup-v2) 
check_for_version()
{
  local local_version_str="$( normalize_version $1 )"
  local required_version_str="$( normalize_version $2 )"
  
  if [[ "$local_version_str" < "$required_version_str" ]]; then
    return 1
  else
    return 0
  fi
}

# Check mysqld binary
if [ -r ${BUILD}/bin/mysqld ]; then
  BIN=${BUILD}/bin/mysqld
else
  echo "Assert: there is no (script readable) mysqld binary at ${BUILD}/bin/mysqld ?"
  exit 1
fi

declare MYSQL_VERSION=$(${BUILD}/bin/mysqld --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)
declare XTRABACKUP_VERSION=$(xtrabackup --version 2>&1 | grep -oe '[0-9]\.[0-9][\.0-9]*' | head -n1)

#Check xtrabackup binary
if ! check_for_version $MYSQL_VERSION "8.0.0" ; then
  if [[ ! -e `which xtrabackup` ]];then
    echo -e "ERROR! xtrabackup not in path: $PATH"
    echo -e "xtrabackup is required for SST. For more info: https://www.percona.com/doc/percona-xtradb-cluster/5.7/manual/state_snapshot_transfer.html"
    exit 1
  fi
fi

if check_for_version $MYSQL_VERSION "8.0.0" ; then 
  if ! check_for_version $XTRABACKUP_VERSION "8.0.0" ; then
	echo "Xtrabackup version($XTRABACKUP_VERSION) do not support current Percona XtraDB cluster version($MYSQL_VERSION). Terminating."
	exit 1
  fi
else
  KEY_RING_CHECK=1
fi

if [ ! -r $BUILD/mysql-test/mysql-test-run.pl ]; then
  echo -e "mysql test suite is not available, please check.."
fi

ADDR="127.0.0.1"
RPORT=$(( RANDOM%21 + 10 ))
RBASE="$(( RPORT*1000 ))"
LADDR="$ADDR:$(( RBASE + 8 ))"
SUSER=root
SPASS=
node0="${BUILD}/node0"
keyring_node0="${BUILD}/keyring_node0"

KEY_RING_CHECK=0
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then 
  mkdir -p $node0 $keyring_node0
else
  KEY_RING_CHECK=1
fi

echo -e "#!/bin/bash" > ./start_pxc

echo -e "if [ -z \$1 ]; then"  >> ./start_pxc
echo -e "  echo \"Usage: start_pxc <number-of-nodes-in-cluster>\""  >> ./start_pxc
echo -e "  exit 1"  >> ./start_pxc
echo -e "fi"  >> ./start_pxc
echo -e "if ! [[ \$1 =~ ^[0-9]+$ ]]; then"  >> ./start_pxc
echo -e "  echo \"Given parameter is not an integer\""  >> ./start_pxc
echo -e "  exit 1"  >> ./start_pxc
echo -e "fi"  >> ./start_pxc
echo -e "NODES=\$1"  >> ./start_pxc
echo -e "RBASE=\"$(( RPORT*1000 ))\""  >> ./start_pxc
echo -e "LADDR=\"$ADDR:$(( RBASE + 8 ))\""  >> ./start_pxc
echo -e "PXC_MYEXTRA=\"\" # Please add your custom configurations here. eg : --wsrep-debug=1" >> ./start_pxc
echo -e "PXC_START_TIMEOUT=200"  >> ./start_pxc
echo -e "KEY_RING_CHECK=$KEY_RING_CHECK"  >> ./start_pxc
echo -e "BUILD=\$(pwd)\n"  >> ./start_pxc
echo -e "echo 'Starting PXC nodes..'\n" >> ./start_pxc

echo -e "if [ -z \$NODES ]; then"  >> ./start_pxc
echo -e "  echo \"+----------------------------------------------------------------+\""  >> ./start_pxc
echo -e "  echo \"| ** Triggered default startup. Starting single node cluster  ** |\""  >> ./start_pxc
echo -e "  echo \"+----------------------------------------------------------------+\""  >> ./start_pxc
echo -e "  echo \"|  To start multiple nodes please execute script as;             |\""  >> ./start_pxc
echo -e "  echo \"|  $./start_pxc.sh 2                                             |\""  >> ./start_pxc
echo -e "  echo \"|  This would lead to start 2 node cluster                       |\""  >> ./start_pxc
echo -e "  echo \"+----------------------------------------------------------------+\""  >> ./start_pxc
echo -e "  NODES=1"  >> ./start_pxc
#echo -e "else"  >> ./start_pxc
#echo -e "  let NODES=NODES-1" >> ./start_pxc
echo -e "fi"  >> ./start_pxc

if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
  echo -e "MID=\"${BUILD}/scripts/mysql_install_db --no-defaults --basedir=${BUILD}\"" >> ./start_pxc
else
  echo -e "MID=\"${BUILD}/bin/mysqld --no-defaults --initialize-insecure --basedir=${BUILD}\"" >> ./start_pxc
fi
echo -e "function start_multi_node(){" >> ./start_pxc
echo -e "  for i in \`seq 1 \$NODES\`;do" >> ./start_pxc
echo -e "    RBASE1=\"\$(( RBASE + ( 100 * \$i ) ))\"" >> ./start_pxc
echo -e "    LADDR1=\"$ADDR:\$(( RBASE1 + 8 ))\"" >> ./start_pxc
echo -e "    if [ \$i -eq 1 ];then" >> ./start_pxc
echo -e "      WSREP_CLUSTER=\"gcomm://\"" >> ./start_pxc
echo -e "    else" >> ./start_pxc
echo -e "      WSREP_CLUSTER=\"\$WSREP_CLUSTER,\$LADDR1\"" >> ./start_pxc
echo -e "    fi" >> ./start_pxc
echo -e "    node=\"${BUILD}/node\$i\"" >> ./start_pxc
if ! check_for_version $MYSQL_VERSION "5.7.0" ; then
  echo -e "    mkdir -p \$node" >> ./start_pxc
fi
echo -e "    if [ ! -d \$node ]; then" >> ./start_pxc
echo -e "      \${MID} --datadir=\$node  > \${BUILD}/startup_node\$i.err 2>&1 || exit 1;" >> ./start_pxc
echo -e "    fi\n" >> ./start_pxc
echo -e "    touch ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"[mysqld]\" > ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"basedir=\${BUILD}\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"datadir=\$node\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"innodb_file_per_table\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"innodb_autoinc_lock_mode=2\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep-provider=\${BUILD}/lib/libgalera_smm.so\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep_cluster_address=\$WSREP_CLUSTER\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep_node_incoming_address=$ADDR\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep_provider_options=gmcast.listen_addr=tcp://\$LADDR1\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep_sst_method=$sst_method\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep_node_address=$ADDR\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"core-file\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"log-error=\$node/node\$i.err\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"log-error-verbosity=3\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"socket=\$node/socket.sock\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"log-output=none\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"port=\$RBASE1\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"server-id=1\$i\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
echo -e "    echo \"wsrep_slave_threads=2\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc

if ! check_for_version $MYSQL_VERSION "8.0.0" ; then
  echo -e "    echo \"wsrep_sst_auth=$SUSER:$SPASS\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
else
  echo -e "    echo \"pxc_encrypt_cluster_traffic=OFF\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
fi
if check_for_version $MYSQL_VERSION "5.7.0" ; then
  echo -e "    echo \"pxc_maint_transition_period=1\" >> ${BUILD}/node\$i.cnf " >> ./start_pxc
fi
echo -e "    \${BUILD}/bin/mysqld --defaults-file=${BUILD}/node\$i.cnf  \\" >> ./start_pxc
echo -e "      \$PXC_MYEXTRA > \$node/node\$i.err 2>&1 &\n" >> ./start_pxc

echo -e "    for X in \$(seq 0 \${PXC_START_TIMEOUT}); do" >> ./start_pxc
echo -e "      sleep 1" >> ./start_pxc
echo -e "      if \${BUILD}/bin/mysqladmin -uroot -S\$node/socket.sock ping > /dev/null 2>&1; then" >> ./start_pxc
echo -e "        if [ \"\`\${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse\"show global status like 'wsrep_local_state_comment'\" | awk '{print \$2}'\`\" == \"Synced\" ]; then" >> ./start_pxc
echo -e "          echo \"Server on socket \${node}/socket.sock with datadir \${node} started\"" >> ./start_pxc
echo -e "          echo \" Configuration file : ${BUILD}/node\$i.cnf\"" >> ./start_pxc
echo -e "          break" >> ./start_pxc
echo -e "        fi" >> ./start_pxc
echo -e "      fi" >> ./start_pxc
echo -e "      if [[ \${X} -eq 200 ]] ; then" >> ./start_pxc
echo -e "        echo \"Server on socket \${node}/socket.sock with datadir \${node} failed\"" >> ./start_pxc
echo -e "        echo \"************************* ERROR *******************************\"" >> ./start_pxc
echo -e "        grep -i '\\[ERROR\\]' \${node}/node\${i}.err" >> ./start_pxc
echo -e "        echo \"************************* ERROR *******************************\"" >> ./start_pxc
echo -e "        exit 1" >> ./start_pxc
echo -e "      fi" >> ./start_pxc
echo -e "    done" >> ./start_pxc

echo -e "    if [ \$i -eq 1 ];then" >> ./start_pxc
echo -e "      echo -e \"\${BUILD}/bin/mysqladmin -uroot -S\$node/socket.sock shutdown\" > ./stop_pxc" >> ./start_pxc
echo -e "      echo -e \"echo 'Server on socket \$node/socket.sock with datadir \$node halted'\" >> ./stop_pxc" >> ./start_pxc
echo -e "      echo -e \"if [ -r ./stop_pxc ]; then ./stop_pxc 2>/dev/null 1>&2; fi\" > ./wipe" >> ./start_pxc
echo -e "      WSREP_CLUSTER=\"gcomm://\$LADDR1\"" >> ./start_pxc
echo -e "      \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -e'create database if not exists test' > /dev/null 2>&1" >> ./start_pxc
echo -e "    else" >> ./start_pxc
echo -e "      echo -e \"echo 'Server on socket \$node/socket.sock with datadir \$node halted'\" | cat - ./stop_pxc > ./temp && mv ./temp ./stop_pxc"  >> ./start_pxc
echo -e "      echo -e \"\${BUILD}/bin/mysqladmin -uroot -S\$node/socket.sock shutdown\" | cat - ./stop_pxc > ./temp && mv ./temp ./stop_pxc"  >> ./start_pxc
echo -e "    fi" >> ./start_pxc

echo -e "    echo -e \"if [ -d \$node.PREV ]; then rm -Rf \$node.PREV.older; mv \$node.PREV \$node.PREV.older; fi;mv \$node \$node.PREV\" >> ./wipe"  >> ./start_pxc
echo -e "    echo -e \"\$BUILD/bin/mysql -A -uroot -S\$node/socket.sock --prompt \\\"node\$i:\\u@\\h> \\\"\" > \${BUILD}/\$i\\_node_cli "  >> ./start_pxc
echo -e "    chmod +x  \${BUILD}/\$i\\_node_cli  "  >> ./start_pxc

echo -e "  done\n" >> ./start_pxc
echo -e "}\n" >> ./start_pxc

echo -e "start_multi_node" >> ./start_pxc
echo -e "chmod +x ./stop_pxc ./*node_cli ./wipe" >> ./start_pxc

if [ ${ADD_SYSBENCH_SCRIPTS} -eq 1 ]; then
  if [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "0.5" ]; then
    if check_for_version $MYSQL_VERSION "8.0.0" ; then
      echo "${PWD}/bin/mysql -uroot --socket=${BUILD}/node1/socket.sock -e \"CREATE USER IF NOT EXISTS sysbench_user@'%' identified with mysql_native_password by 'test';GRANT ALL ON *.* TO sysbench_user@'%'\" 2>&1" > sysbench_prepare
      echo "sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp_table_size=1000000 --oltp_tables_count=1 --mysql-db=test --mysql-user=sysbench_user --mysql-password=test  --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock prepare" >> sysbench_prepare
      echo "sysbench --report-interval=10 --max-time=50 --max-requests=0 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=1 --num-threads=4 --oltp_table_size=1000000 --mysql-db=test --mysql-user=sysbench_user --mysql-password=test  --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock run" > sysbench_run
    else
      echo "sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp_table_size=1000000 --oltp_tables_count=1 --mysql-db=test --mysql-user=root  --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock prepare" > sysbench_prepare
      echo "sysbench --report-interval=10 --max-time=50 --max-requests=0 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=1 --num-threads=4 --oltp_table_size=1000000 --mysql-db=test --mysql-user=root  --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock run" > sysbench_run
    fi
  elif [ "$(sysbench --version | cut -d ' ' -f2 | grep -oe '[0-9]\.[0-9]')" == "1.0" ]; then
    if check_for_version $MYSQL_VERSION "8.0.0" ; then
      echo "${PWD}/bin/mysql -uroot --socket=${BUILD}/node1/socket.sock -e \"CREATE USER IF NOT EXISTS sysbench_user@'%' identified with mysql_native_password by 'test';GRANT ALL ON *.* TO sysbench_user@'%'\" 2>&1" > sysbench_prepare
      echo "sysbench /usr/share/sysbench/oltp_insert.lua  --mysql-storage-engine=innodb --table-size=1000000 --tables=1 --mysql-db=test --mysql-user=sysbench_user --mysql-password=test  --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock prepare" >> sysbench_prepare
      echo "sysbench /usr/share/sysbench/oltp_read_write.lua --report-interval=10 --time=50 --events=0 --index_updates=10 --non_index_updates=10 --distinct_ranges=15 --order_ranges=15 --tables=1 --threads=4  --table-size=1000000 --mysql-db=test --mysql-user=sysbench_user --mysql-password=test  --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock run" > sysbench_run
    else
      echo "sysbench /usr/share/sysbench/oltp_insert.lua  --mysql-storage-engine=innodb --table-size=1000000 --tables=1 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock prepare" > sysbench_prepare
      echo "sysbench /usr/share/sysbench/oltp_read_write.lua --report-interval=10 --time=50 --events=0 --index_updates=10 --non_index_updates=10 --distinct_ranges=15 --order_ranges=15 --tables=1 --threads=4  --table-size=1000000 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${BUILD}/node1/socket.sock run" > sysbench_run
    fi
  fi
fi

if [ ${ADD_SYSBENCH_SCRIPTS} -eq 1 ]; then
  echo -e "Added scripts: ./start_pxc ./sysbench_prepare ./sysbench_run"
  echo -e "./start_pxc will create ./stop_pxc | ./*node_cli | ./wipe scripts"
  chmod +x ./start_pxc ./sysbench_prepare ./sysbench_run
else
  echo -e "Added scripts: ./start_pxc"
  echo -e "./start_pxc will create ./stop_pxc | ./*node_cli | ./wipe scripts"
  chmod +x ./start_pxc
fi
