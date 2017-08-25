#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

PORT=$[$RANDOM % 10000 + 10000]
MTRT=$[$RANDOM % 100 + 700]
BUILD=$(pwd | sed 's|^.*/||')
SCRIPT_PWD=$(cd `dirname $0` && pwd)

if find . -name group_replication.so | grep -q . ; then 
  GRP_RPL=1
else
  echo "Warning! Group Replication plugin not found. Skipping Group Replication startup"
  GRP_RPL=0
fi

JE1="if [ -r /usr/lib64/libjemalloc.so.1 ]; then export LD_PRELOAD=/usr/lib64/libjemalloc.so.1"
JE2=" elif [ -r /usr/lib/x86_64-linux-gnu/libjemalloc.so.1 ]; then export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.1"
JE3=" elif [ -r /usr/local/lib/libjemalloc.so ]; then export LD_PRELOAD=/usr/local/lib/libjemalloc.so"
JE4=" elif [ -r ${PWD}/lib/mysql/libjemalloc.so.1 ]; then export LD_PRELOAD=${PWD}/lib/mysql/libjemalloc.so.1"
JE5=" else echo 'Error: jemalloc not found, please install it first'; exit 1; fi" 

# Ubuntu mysqld runtime provisioning
if [ "$(uname -v | grep 'Ubuntu')" != "" ]; then
  if [ "$(sudo apt-get -s install libaio1 | grep 'is already')" == "" ]; then
    sudo apt-get install libaio1 
  fi
  if [ "$(sudo apt-get -s install libjemalloc1 | grep 'is already')" == "" ]; then
    sudo apt-get install libjemalloc1
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libssl.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libssl.so.1.0.0 /lib/x86_64-linux-gnu/libssl.so.6
  fi
  if [ ! -r /lib/x86_64-linux-gnu/libcrypto.so.6 ]; then
    sudo ln -s /lib/x86_64-linux-gnu/libcrypto.so.1.0.0 /lib/x86_64-linux-gnu/libcrypto.so.6
  fi
fi

# Get version specific options
BIN=
if [ -r ${PWD}/bin/mysqld-debug ]; then BIN="${PWD}/bin/mysqld-debug"; fi  # Needs to come first so it's overwritten in next line if both exist
if [ -r ${PWD}/bin/mysqld ]; then BIN="${PWD}/bin/mysqld"; fi
if [ "${BIN}" == "" ]; then echo "Assert: no mysqld or mysqld-debug binary was found!"; fi
MID=
if [ -r ${PWD}/scripts/mysql_install_db ]; then MID="${PWD}/scripts/mysql_install_db"; fi
if [ -r ${PWD}/bin/mysql_install_db ]; then MID="${PWD}/bin/mysql_install_db"; fi
START_OPT="--core-file"           # Compatible with 5.6,5.7,8.0
INIT_OPT="--initialize-insecure"  # Compatible with     5.7,8.0 (mysqld init)
INIT_TOOL="${BIN}"                # Compatible with     5.7,8.0 (mysqld init), changed to MID later if version <=5.6
VERSION_INFO=$(${BIN} --version | grep -oe '[58]\.[01567]' | head -n1)
if [ "${VERSION_INFO}" == "5.1" -o "${VERSION_INFO}" == "5.5" -o "${VERSION_INFO}" == "5.6" ]; then
  if [ "${MID}" == "" ]; then 
    echo "Assert: Version was detected as ${VERSION_INFO}, yet ./scripts/mysql_install_db nor ./bin/mysql_install_db is present!"
    exit 1
  fi
  INIT_TOOL="${MID}"
  INIT_OPT="--force --no-defaults"
  START_OPT="--core"
elif [ "${VERSION_INFO}" != "5.7" -a "${VERSION_INFO}" != "8.0" ]; then
  echo "WARNING: mysqld (${BIN}) version detection failed. This is likely caused by using this script with a non-supported distribution or version of mysqld. Please expand this script to handle (which shoud be easy to do). Even so, the scipt will now try and continue as-is, but this may fail."
fi

# Setup scritps
if [[ $GRP_RPL -eq 1 ]];then
  echo "Adding scripts: start | start_group_replication | start_valgrind | start_gypsy | stop | kill | setup | cl | test | init | wipe | all | prepare | run | measure | myrocks_tokudb_init"
  rm -f start start_group_replication start_valgrind start_gypsy stop setup cl test init wipe all prepare run measure myrocks_tokudb_init pmm_os_agent pmm_mysql_agent stop_group_replication *cl wipe_group_replication
else
  echo "Adding scripts: start | start_valgrind | start_gypsy | stop | kill | setup | cl | test | init | wipe | all | prepare | run | measure | myrocks_tokudb_init"
  rm -f start start_valgrind start_gypsy stop setup cl test init wipe all prepare run measure myrocks_tokudb_init pmm_os_agent pmm_mysql_agent
fi

#GR startup scripts
if [[ $GRP_RPL -eq 1 ]];then
  echo -e "#!/bin/bash" > ./start_group_replication
  echo -e "NODES=\$1"  >> ./start_group_replication
  echo -e "ADDR=\"127.0.0.1\""  >> ./start_group_replication
  echo -e "RPORT=$(( RANDOM%21 + 10 ))"  >> ./start_group_replication
  echo -e "RBASE=\"\$(( RPORT*1000 ))\""  >> ./start_group_replication
  echo -e "MYEXTRA=\"\"" >> ./start_group_replication
  echo -e "GR_START_TIMEOUT=300"  >> ./start_group_replication
  echo -e "BUILD=\$(pwd)\n"  >> ./start_group_replication
  echo -e "touch ./stop_group_replication " >> ./start_group_replication
  echo -e "if [ -z \$NODES ]; then"  >> ./start_group_replication
  echo -e "  echo \"No valid parameter is passed. Need to pass how many nodes to start. Retry.\""  >> ./start_group_replication
  echo -e "  echo \"Usage example:\""  >> ./start_group_replication
  echo -e "  echo \"   $./start_group_replication 2\""  >> ./start_group_replication
  echo -e "  echo \"   This would start a 2 node Group Replication cluster.\""  >> ./start_group_replication
  echo -e "  exit 1"  >> ./start_group_replication
  echo -e "else"  >> ./start_group_replication
  echo -e "  echo \"Starting \$NODES node Group Replication, please wait...\""  >> ./start_group_replication
  echo -e "  rm -f ./stop_group_replication ./*cl ./wipe_group_replication" >> ./start_group_replication
  echo -e "  touch ./stop_group_replication" >> ./start_group_replication
  echo -e "fi"  >> ./start_group_replication

  echo -e "MID=\"\${BUILD}/bin/mysqld --no-defaults --initialize-insecure --basedir=\${BUILD}\"" >> ./start_group_replication

  if [[ $i -eq 1 ]]; then
    GR_GROUP_SEEDS=$LADDR
  else
    GR_GROUP_SEEDS=$GR_GROUP_SEEDS,$LADDR
  fi

  echo -e "for i in \`seq 1 \$NODES\`;do" >> ./start_group_replication
  echo -e "  LADDR=\"\$ADDR:\$(( RBASE + 100 + \$i ))\"" >> ./start_group_replication
  echo -e "  if [[ \$i -eq 1 ]]; then"  >> ./start_group_replication
  echo -e "    GR_GROUP_SEEDS="\$LADDR"" >> ./start_group_replication
  echo -e "  else"  >> ./start_group_replication
  echo -e "    GR_GROUP_SEEDS=\"\$GR_GROUP_SEEDS,\$LADDR\"" >> ./start_group_replication
  echo -e "  fi"  >> ./start_group_replication
  echo -e "done" >> ./start_group_replication

  echo -e "function start_multi_node(){" >> ./start_group_replication
  echo -e "  NODE_CHK=0" >> ./start_group_replication
  echo -e "  for i in \`seq 1 \$NODES\`;do" >> ./start_group_replication
  echo -e "    RBASE1=\"\$(( RBASE + \$i ))\"" >> ./start_group_replication
  echo -e "    LADDR1=\"\$ADDR:\$(( RBASE + 100 + \$i ))\"" >> ./start_group_replication
  echo -e "    node=\"\${BUILD}/node\$i\"" >> ./start_group_replication
  echo -e "    if [ ! -d \$node ]; then" >> ./start_group_replication
  echo -e "      \${MID} --datadir=\$node  > \${BUILD}/startup_node\$i.err 2>&1 || exit 1;" >> ./start_group_replication
  echo -e "      NODE_CHK=1" >> ./start_group_replication
  echo -e "    fi\n" >> ./start_group_replication

  echo -e "    \${BUILD}/bin/mysqld --no-defaults \\" >> ./start_group_replication
  echo -e "      --basedir=\${BUILD} --datadir=\$node \\" >> ./start_group_replication
  echo -e "      --innodb_file_per_table \$MYEXTRA --innodb_autoinc_lock_mode=2 --innodb_locks_unsafe_for_binlog=1 \\" >> ./start_group_replication
  echo -e "      --server_id=1 --gtid_mode=ON --enforce_gtid_consistency=ON \\" >> ./start_group_replication
  echo -e "      --master_info_repository=TABLE --relay_log_info_repository=TABLE \\" >> ./start_group_replication
  echo -e "      --binlog_checksum=NONE --log_slave_updates=ON --log_bin=binlog \\" >> ./start_group_replication
  echo -e "      --binlog_format=ROW --innodb_flush_method=O_DIRECT \\" >> ./start_group_replication
  echo -e "      --core-file  --sql-mode=no_engine_substitution \\" >> ./start_group_replication
  echo -e "      --secure-file-priv= --loose-innodb-status-file=1 \\" >> ./start_group_replication
  echo -e "      --log-error=\$node/node\$i.err --socket=\$node/socket.sock --log-output=none \\" >> ./start_group_replication
  echo -e "      --port=\$RBASE1 --transaction_write_set_extraction=XXHASH64 \\" >> ./start_group_replication
  echo -e "      --loose-group_replication_group_name=\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\" \\" >> ./start_group_replication
  echo -e "      --loose-group_replication_start_on_boot=off --loose-group_replication_local_address=\$LADDR1 \\" >> ./start_group_replication
  echo -e "      --loose-group_replication_group_seeds=\$GR_GROUP_SEEDS \\" >> ./start_group_replication
  echo -e "      --loose-group_replication_bootstrap_group=off --super_read_only=OFF > \$node/node\$i.err 2>&1 &\n" >> ./start_group_replication

  echo -e "    for X in \$(seq 0 \${GR_START_TIMEOUT}); do" >> ./start_group_replication
  echo -e "      sleep 1" >> ./start_group_replication
  echo -e "      if \${BUILD}/bin/mysqladmin -uroot -S\$node/socket.sock ping > /dev/null 2>&1; then" >> ./start_group_replication
  echo -e "        if [ \$NODE_CHK -eq 1 ]; then" >> ./start_group_replication
  echo -e "          \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"SET SQL_LOG_BIN=0;CREATE USER rpl_user@'%';GRANT REPLICATION SLAVE ON *.* TO rpl_user@'%' IDENTIFIED BY 'rpl_pass';FLUSH PRIVILEGES;SET SQL_LOG_BIN=1;\" > /dev/null 2>&1" >> ./start_group_replication
  echo -e "          \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='rpl_pass' FOR CHANNEL 'group_replication_recovery';\" > /dev/null 2>&1" >> ./start_group_replication
  echo -e "          if [[ \$i -eq 1 ]]; then"  >> ./start_group_replication
  echo -e "            \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"INSTALL PLUGIN group_replication SONAME 'group_replication.so';SET GLOBAL group_replication_bootstrap_group=ON;START GROUP_REPLICATION;SET GLOBAL group_replication_bootstrap_group=OFF;\" > /dev/null 2>&1"  >> ./start_group_replication
  echo -e "            \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"create database if not exists test\" > /dev/null 2>&1" >> ./start_group_replication
  echo -e "          else"  >> ./start_group_replication
  echo -e "            \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"INSTALL PLUGIN group_replication SONAME 'group_replication.so';START GROUP_REPLICATION;\" > /dev/null 2>&1"  >> ./start_group_replication
  echo -e "          fi"  >> ./start_group_replication
  echo -e "        else"  >> ./start_group_replication
  echo -e "          if [[ \$i -eq 1 ]]; then"  >> ./start_group_replication
  echo -e "            \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"SET GLOBAL group_replication_bootstrap_group=ON;START GROUP_REPLICATION;SET GLOBAL group_replication_bootstrap_group=OFF;\" > /dev/null 2>&1"  >> ./start_group_replication
  echo -e "          else"  >> ./start_group_replication
  echo -e "            \${BUILD}/bin/mysql -uroot -S\$node/socket.sock -Bse \"START GROUP_REPLICATION;\" > /dev/null 2>&1"  >> ./start_group_replication
  echo -e "          fi"  >> ./start_group_replication
  echo -e "        fi"  >> ./start_group_replication
  echo -e "        echo \"Started node\$i.\""  >> ./start_group_replication
  echo -e "        CLI_SCRIPTS=\"\$CLI_SCRIPTS | \${i}cl \""  >> ./start_group_replication
  echo -e "        break" >> ./start_group_replication
  echo -e "      fi" >> ./start_group_replication
  echo -e "    done" >> ./start_group_replication

  echo -e "    echo -e \"echo 'Server on socket \$node/socket.sock with datadir \$node halted'\" | cat - ./stop_group_replication > ./temp && mv ./temp ./stop_group_replication"  >> ./start_group_replication
  echo -e "    echo -e \"\${BUILD}/bin/mysqladmin -uroot -S\$node/socket.sock shutdown\" | cat - ./stop_group_replication > ./temp && mv ./temp ./stop_group_replication"  >> ./start_group_replication
  echo -e "    echo -e \"if [ -d \$node.PREV ]; then rm -Rf \$node.PREV.older; mv \$node.PREV \$node.PREV.older; fi;mv \$node \$node.PREV\" >> ./wipe_group_replication"  >> ./start_group_replication
  echo -e "    echo -e \"\$BUILD/bin/mysql -A -uroot -S\$node/socket.sock --prompt \\\"node\$i> \\\"\" > \${BUILD}/\${i}cl "  >> ./start_group_replication
  echo -e "  done\n" >> ./start_group_replication
  echo -e "}\n" >> ./start_group_replication

  echo -e "start_multi_node" >> ./start_group_replication
  echo -e "chmod +x ./stop_group_replication ./*cl ./wipe_group_replication" >> ./start_group_replication
  echo -e "echo \"Added scripts: \$CLI_SCRIPTS | wipe_group_replication | stop_group_replication \""  >> ./start_group_replication
  echo -e "echo \"Started \$NODES Node Group Replication. You may access the clients using the scripts above\""  >> ./start_group_replication
  echo -e "echo \"Please note the wipe_group_replication script is specific for this number of nodes. To setup a completely new Group Replication setup, please use ./start_group_replication again.\""  >> ./start_group_replication
  chmod +x ./start_group_replication
fi

mkdir -p data data/mysql log
if [ -r ${PWD}/lib/mysql/plugin/ha_tokudb.so ]; then
  TOKUDB="--plugin-load-add=tokudb=ha_tokudb.so --tokudb-check-jemalloc=0"
else
  TOKUDB=""
fi
if [ -r ${PWD}/lib/mysql/plugin/ha_rocksdb.so ]; then
  ROCKSDB="--plugin-load-add=rocksdb=ha_rocksdb.so"
else
  ROCKSDB=""
fi

if [[ ! -z $TOKUDB ]]; then
  LOAD_TOKUDB_INIT_FILE="${SCRIPT_PWD}/TokuDB.sql"
else
  LOAD_TOKUDB_INIT_FILE=""
fi
if [[ ! -z $ROCKSDB ]];then
  LOAD_ROCKSDB_INIT_FILE="${SCRIPT_PWD}/MyRocks.sql"
else
  LOAD_ROCKSDB_INIT_FILE=""
fi

echo 'MYEXTRA=" --no-defaults"' > start
echo '#MYEXTRA=" --no-defaults --sql_mode="' >> start
echo "#MYEXTRA=\" --no-defaults --performance-schema --performance-schema-instrument='%=on'\"  # For PMM" >> start
echo '#MYEXTRA=" --no-defaults --default-tmp-storage-engine=MyISAM --rocksdb --skip-innodb --default-storage-engine=RocksDB"' >> start
echo '#MYEXTRA=" --no-defaults --event-scheduler=ON --maximum-bulk_insert_buffer_size=1M --maximum-join_buffer_size=1M --maximum-max_heap_table_size=1M --maximum-max_join_size=1M --maximum-myisam_max_sort_file_size=1M --maximum-myisam_mmap_size=1M --maximum-myisam_sort_buffer_size=1M --maximum-optimizer_trace_max_mem_size=1M --maximum-preload_buffer_size=1M --maximum-query_alloc_block_size=1M --maximum-query_prealloc_size=1M --maximum-range_alloc_block_size=1M --maximum-read_buffer_size=1M --maximum-read_rnd_buffer_size=1M --maximum-sort_buffer_size=1M --maximum-tmp_table_size=1M --maximum-transaction_alloc_block_size=1M --maximum-transaction_prealloc_size=1M --log-output=none --sql_mode=ONLY_FULL_GROUP_BY"' >> start
echo $JE1 >> start; echo $JE2 >> start; echo $JE3 >> start; echo $JE4 >> start; echo $JE5 >> start
cp start start_valgrind  # Idem for Valgrind
cp start start_gypsy     # Just copying jemalloc commands from last line above over to gypsy start also
echo "$BIN \${MYEXTRA} ${START_OPT} --basedir=${PWD} --tmpdir=${PWD}/data --datadir=${PWD}/data ${TOKUDB} ${ROCKSDB} --socket=${PWD}/socket.sock --port=$PORT --log-error=${PWD}/log/master.err 2>&1 &" >> start
echo "sleep 10" >> start
if [ "${VERSION_INFO}" != "5.1" -a "${VERSION_INFO}" != "5.5" -a "${VERSION_INFO}" != "5.6" ]; then
  echo "${PWD}/bin/mysql -uroot --socket=${PWD}/socket.sock  -e'CREATE DATABASE IF NOT EXISTS test;'" >> start
fi

echo "ps -ef | grep \"\$(whoami)\" | grep ${PORT} | grep -v grep | awk '{print \$2}' | xargs kill -9" > kill
echo " valgrind --suppressions=${PWD}/mysql-test/valgrind.supp --num-callers=40 --show-reachable=yes $BIN \${MYEXTRA} ${START_OPT} --basedir=${PWD} --tmpdir=${PWD}/data --datadir=${PWD}/data ${TOKUDB} --socket=${PWD}/socket.sock --port=$PORT --log-error=${PWD}/log/master.err >>${PWD}/log/master.err 2>&1 &" >> start_valgrind
echo "$BIN \${MYEXTRA} ${START_OPT} --general_log=1 --general_log_file=${PWD}/general.log --basedir=${PWD} --tmpdir=${PWD}/data --datadir=${PWD}/data ${TOKUDB} --socket=${PWD}/socket.sock --port=$PORT --log-error=${PWD}/log/master.err 2>&1 &" >> start_gypsy
echo "echo 'Server socket: ${PWD}/socket.sock with datadir: ${PWD}/data'" >> start
tail -n1 start >> start_valgrind
tail -n1 start >> start_gypsy
echo "${PWD}/bin/mysqladmin -uroot -S${PWD}/socket.sock shutdown" > stop
echo "echo 'Server on socket ${PWD}/socket.sock with datadir ${PWD}/data halted'" >> stop
echo "./init;./start;sleep 5;./cl;./stop;tail log/master.err" > setup
if [ ! -z $LOAD_TOKUDB_INIT_FILE ]; then
  echo "./start; sleep 10; ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock < ${LOAD_TOKUDB_INIT_FILE}" > myrocks_tokudb_init
  if [ ! -z $LOAD_ROCKSDB_INIT_FILE ] ; then
    echo " ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock < ${LOAD_ROCKSDB_INIT_FILE} ; ./stop " >> myrocks_tokudb_init
  else
    echo "./stop " >> myrocks_tokudb_init
  fi
else
  if [[ ! -z $LOAD_ROCKSDB_INIT_FILE ]];then
    echo "./start; sleep 10; ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock < ${LOAD_ROCKSDB_INIT_FILE} ; ./stop" > myrocks_tokudb_init
  fi
fi

BINMODE=
if [ "${VERSION_INFO}" != "5.1" -a "${VERSION_INFO}" != "5.5" ]; then
  BINMODE="--binary-mode "  # Leave trailing space
fi
echo "${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock --force --prompt=\"\$(${PWD}/bin/mysqld --version | grep -o 'Ver [\\.0-9]\\+' | sed 's|[^\\.0-9]*||')>\" ${BINMODE}test" > cl
echo "${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock --force --version | grep -o 'Ver [\\.0-9]\\+' | sed 's|[^\\.0-9]*||')>\" ${BINMODE}test" > cl_noprompt
echo "${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock --force ${BINMODE}test < ${PWD}/in.sql > ${PWD}/mysql.out 2>&1" > test
echo "./stop >/dev/null 2>&1" > wipe
echo "if [ -d ${PWD}/data.PREV ]; then rm -Rf ${PWD}/data.PREV.older; mv ${PWD}/data.PREV ${PWD}/data.PREV.older; fi; mv ${PWD}/data ${PWD}/data.PREV" >> wipe
echo "sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-auto-inc=off --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp_table_size=1000000 --oltp_tables_count=1 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${PWD}/socket.sock prepare" > prepare
echo "sysbench --report-interval=10 --oltp-auto-inc=off --max-time=50 --max-requests=0 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=1 --num-threads=4 --oltp_table_size=1000000 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${PWD}/socket.sock run" > run
echo "./stop;./wipe;./start;sleep 3;./prepare;./run;./stop" > measure
echo "$INIT_TOOL --no-defaults ${INIT_OPT} --basedir=${PWD} --datadir=${PWD}/data" >> wipe
echo "if [ -r log/master.err.PREV ]; then rm -f log/master.err.PREV; fi" >> wipe
echo "if [ -r log/master.err ]; then mv log/master.err log/master.err.PREV; fi" >> wipe
if [ ! -z $LOAD_TOKUDB_INIT_FILE ]; then
  echo "./start; sleep 10; ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock < ${LOAD_TOKUDB_INIT_FILE} ; ${PWD}/bin/mysql -uroot --socket=${PWD}/socket.sock  -e'CREATE DATABASE IF NOT EXISTS test' ;" >> wipe
  if [ ! -z $LOAD_ROCKSDB_INIT_FILE ] ; then
    echo " ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock < ${LOAD_ROCKSDB_INIT_FILE} ; ./stop " >> wipe
  else
    echo "./stop " >> wipe
  fi
else
  if [[ ! -z $LOAD_ROCKSDB_INIT_FILE ]];then
    echo "./start; sleep 10; ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock < ${LOAD_ROCKSDB_INIT_FILE} ;${PWD}/bin/mysql -uroot --socket=${PWD}/socket.sock  -e'CREATE DATABASE IF NOT EXISTS test' ; ./stop" >> wipe
  else
    echo "./start; sleep 10; ${PWD}/bin/mysql -uroot --socket=${PWD}/socket.sock  -e'CREATE DATABASE IF NOT EXISTS test' ; ./stop" >> wipe
  fi
fi


echo 'sudo pmm-admin config --server $(ifconfig | grep -A1 "^en" | grep -v "^en" | sed "s|.*inet ||;s| .*||")' > pmm_os_agent
echo 'sudo pmm-admin add mysql $(echo ${PWD} | sed "s|/|-|g;s|^-\+||") --socket=${PWD}/socket.sock --user=root --query-source=perfschema' > pmm_mysql_agent
echo "./stop >/dev/null 2>&1" > init
echo "rm -Rf ${PWD}/data" >> init
echo "$INIT_TOOL --no-defaults ${INIT_OPT} --basedir=${PWD} --datadir=${PWD}/data" >> init
echo "rm -f log/master.*" >> init

echo "./stop >/dev/null 2>&1;./wipe;./start;sleep 5;./cl" > all
chmod +x start start_valgrind start_gypsy stop setup cl cl_noprompt test kill init wipe all prepare run measure myrocks_tokudb_init pmm_os_agent pmm-mysql-agent 2>/dev/null
echo "Setting up server with default directories"
./stop >/dev/null 2>&1
./init
if [[ -r ${PWD}/lib/mysql/plugin/ha_tokudb.so ]] || [[ -r ${PWD}/lib/mysql/plugin/ha_rocksdb.so ]] ; then
  echo "Enabling additional TokuDB/ROCKSDB engine plugin items if exists"
  ./myrocks_tokudb_init
fi
echo "Done! To get a fresh instance at any time, execute: ./all (executes: stop;wipe;start;sleep 5;cl)"
exit 0 
