#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

PORT=$[$RANDOM % 10000 + 10000]
MTRT=$[$RANDOM % 100 + 700]
BUILD=$(pwd | sed 's|^.*/||')

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
echo "Adding scripts: start | start_valgrind | start_gypsy | stop | kill | setup | cl | test | init | wipe | all | prepare | run | measure | tokutek_init"
rm -f start start_valgrind start_gypsy stop setup cl test init wipe all prepare run measure tokutek_init pmm_os_agent pmm_mysql_agent
mkdir -p data data/mysql data/test log
if [ -r ${PWD}/lib/mysql/plugin/ha_tokudb.so ]; then
  TOKUDB="--plugin-load-add=tokudb=ha_tokudb.so --tokudb-check-jemalloc=0"
else
  TOKUDB=""
fi
echo 'MYEXTRA=" --no-defaults"' > start
echo '#MYEXTRA=" --no-defaults --plugin-load-add=rocksdb=ha_rocksdb.so"' >> start
echo '#MYEXTRA=" --no-defaults --sql_mode="' >> start
echo "#MYEXTRA=\" --no-defaults --performance-schema --performance-schema-instrument='%=on'\"  # For PMM" >> start
echo '#MYEXTRA=" --no-defaults --default-tmp-storage-engine=MyISAM --rocksdb --skip-innodb --default-storage-engine=RocksDB"' >> start
echo '#MYEXTRA=" --no-defaults --event-scheduler=ON --maximum-bulk_insert_buffer_size=1M --maximum-join_buffer_size=1M --maximum-max_heap_table_size=1M --maximum-max_join_size=1M --maximum-myisam_max_sort_file_size=1M --maximum-myisam_mmap_size=1M --maximum-myisam_sort_buffer_size=1M --maximum-optimizer_trace_max_mem_size=1M --maximum-preload_buffer_size=1M --maximum-query_alloc_block_size=1M --maximum-query_prealloc_size=1M --maximum-range_alloc_block_size=1M --maximum-read_buffer_size=1M --maximum-read_rnd_buffer_size=1M --maximum-sort_buffer_size=1M --maximum-tmp_table_size=1M --maximum-transaction_alloc_block_size=1M --maximum-transaction_prealloc_size=1M --log-output=none --sql_mode=ONLY_FULL_GROUP_BY"' >> start
echo $JE1 >> start; echo $JE2 >> start; echo $JE3 >> start; echo $JE4 >> start; echo $JE5 >> start
cp start start_valgrind  # Idem for Valgrind
cp start start_gypsy     # Just copying jemalloc commands from last line above over to gypsy start also
echo "$BIN \${MYEXTRA} ${START_OPT} --basedir=${PWD} --tmpdir=${PWD}/data --datadir=${PWD}/data ${TOKUDB} --socket=${PWD}/socket.sock --port=$PORT --log-error=${PWD}/log/master.err 2>&1 &" >> start
echo "ps -ef | grep \"\$(whoami)\" | grep ${PORT} | grep -v grep | awk '{print \$2}' | xargs kill -9" > kill
echo " valgrind --suppressions=${PWD}/mysql-test/valgrind.supp --num-callers=40 --show-reachable=yes $BIN \${MYEXTRA} ${START_OPT} --basedir=${PWD} --tmpdir=${PWD}/data --datadir=${PWD}/data ${TOKUDB} --socket=${PWD}/socket.sock --port=$PORT --log-error=${PWD}/log/master.err >>${PWD}/log/master.err 2>&1 &" >> start_valgrind
echo "$BIN \${MYEXTRA} ${START_OPT} --general_log=1 --general_log_file=${PWD}/general.log --basedir=${PWD} --tmpdir=${PWD}/data --datadir=${PWD}/data ${TOKUDB} --socket=${PWD}/socket.sock --port=$PORT --log-error=${PWD}/log/master.err 2>&1 &" >> start_gypsy
echo "echo 'Server socket: ${PWD}/socket.sock with datadir: ${PWD}/data'" >> start
tail -n1 start >> start_valgrind
tail -n1 start >> start_gypsy
echo "${PWD}/bin/mysqladmin -uroot -S${PWD}/socket.sock shutdown" > stop
echo "echo 'Server on socket ${PWD}/socket.sock with datadir ${PWD}/data halted'" >> stop
echo "./init;./start;sleep 5;./cl;./stop;tail log/master.err" > setup
echo "./start; sleep 10; ${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock -e \"INSTALL PLUGIN tokudb_file_map SONAME 'ha_tokudb.so'; INSTALL PLUGIN tokudb_fractal_tree_info SONAME 'ha_tokudb.so'; INSTALL PLUGIN tokudb_fractal_tree_block_map SONAME 'ha_tokudb.so'; INSTALL PLUGIN tokudb_trx SONAME 'ha_tokudb.so'; INSTALL PLUGIN tokudb_locks SONAME 'ha_tokudb.so'; INSTALL PLUGIN tokudb_lock_waits SONAME 'ha_tokudb.so';\"; ./stop" > tokutek_init
BINMODE=
if [ "${VERSION_INFO}" != "5.1" -a "${VERSION_INFO}" != "5.5" ]; then
  BINMODE="--binary-mode "  # Leave trailing space
fi
echo "${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock --force ${BINMODE}test" > cl
echo "${PWD}/bin/mysql -A -uroot -S${PWD}/socket.sock --force ${BINMODE}test < ${PWD}/in.sql > ${PWD}/mysql.out 2>&1" > test
echo "./stop >/dev/null 2>&1" > wipe
echo "if [ -d ${PWD}/data.PREV ]; then rm -Rf ${PWD}/data.PREV.older; mv ${PWD}/data.PREV ${PWD}/data.PREV.older; fi; mv ${PWD}/data ${PWD}/data.PREV" >> wipe
echo "sysbench --test=/usr/share/doc/sysbench/tests/db/parallel_prepare.lua --oltp-auto-inc=off --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp_table_size=1000000 --oltp_tables_count=1 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${PWD}/socket.sock prepare" > prepare
echo "sysbench --report-interval=10 --oltp-auto-inc=off --max-time=50 --max-requests=0 --mysql-engine-trx=yes --test=/usr/share/doc/sysbench/tests/db/oltp.lua --init-rng=on --oltp_index_updates=10 --oltp_non_index_updates=10 --oltp_distinct_ranges=15 --oltp_order_ranges=15 --oltp_tables_count=1 --num-threads=4 --oltp_table_size=1000000 --mysql-db=test --mysql-user=root --db-driver=mysql --mysql-socket=${PWD}/socket.sock run" > run
echo "./stop;./wipe;./start;sleep 3;./prepare;./run;./stop" > measure
echo "$INIT_TOOL --no-defaults ${INIT_OPT} --basedir=${PWD} --datadir=${PWD}/data" >> wipe
echo "if [ -r log/master.err.PREV ]; then rm -f log/master.err.PREV; fi" >> wipe
echo "if [ -r log/master.err ]; then mv log/master.err log/master.err.PREV; fi" >> wipe
if [ "${VERSION_INFO}" != "5.1" -a "${VERSION_INFO}" != "5.5" -a "${VERSION_INFO}" != "5.6" ]; then
  echo "mkdir ${PWD}/data/test" >> wipe
fi
echo 'sudo pmm-admin config --server $(ifconfig | grep -A1 "^en" | grep -v "^en" | sed "s|.*inet ||;s| .*||")' > pmm_os_agent
echo 'sudo pmm-admin add mysql $(echo ${PWD} | sed "s|/|-|g;s|^-\+||") --socket=${PWD}/socket.sock --user=root --query-source=perfschema' > pmm_mysql_agent
echo "./stop >/dev/null 2>&1" > init
echo "rm -Rf ${PWD}/data" >> init
echo "$INIT_TOOL --no-defaults ${INIT_OPT} --basedir=${PWD} --datadir=${PWD}/data" >> init
echo "rm -f log/master.*" >> init
if [ "${VERSION_INFO}" != "5.1" -a "${VERSION_INFO}" != "5.5" -a "${VERSION_INFO}" != "5.6" ]; then
  echo "mkdir ${PWD}/data/test" >> init
fi
echo "./stop >/dev/null 2>&1;./wipe;./start;sleep 5;./cl" > all
chmod +x start start_valgrind start_gypsy stop setup cl test kill init wipe all prepare run measure tokutek_init pmm_os_agent pmm-mysql-agent 2>/dev/null
echo "Setting up server with default directories"
./stop >/dev/null 2>&1
./init
if [ -r ${PWD}/lib/mysql/plugin/ha_tokudb.so ]; then
  echo "Enabling additional TokuDB engine plugin items"
  ./tokutek_init
fi
echo "Done! To get a fresh instance at any time, execute: ./all (executes: stop;wipe;start;sleep 5;cl)"
exit 0 
