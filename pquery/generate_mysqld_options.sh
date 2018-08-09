#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script quickly and intelligently generates all available mysqld --option combinations (i.e. including values)

# User variables
OUTPUT_FILE=/tmp/mysqld_options.txt

# Internal variables, do not change
TEMP_FILE=/tmp/mysqld_options.tmp

if [ ! -r ./bin/mysqld ]; then
  if [ ! -r ./mysqld ]; then
    echo "This script quickly and intelligently generates all available mysqld --option combinations (i.e. including values)"
    echo "Error: no ./bin/mysqld or ./mysqld found!"
    exit 1
  else
    cd ..
  fi
fi

IS_PXC=0
if ./bin/mysqld --version | grep -q 'Percona XtraDB Cluster' 2>/dev/null ; then 
  IS_PXC=1
fi

echoit(){
  echo "[$(date +'%T')] $1"
  echo "[$(date +'%T')] $1" >> /tmp/generate_mysqld_options.log
}

# Extract all options, their default values, and do some initial cleaning
./bin/mysqld --no-defaults --help --verbose 2>/dev/null | \
 sed '0,/Value (after reading options)/d' | \
 egrep -v "To see what values.*is using|mysqladmin.*instead of|^[ \t]*$|\-\-\-" \
 > ${TEMP_FILE}

# mysqld options excluded from list
# RV/HM 18.07.2017 Temporarily added to EXCLUDED_LIST: --binlog-group-commit-sync-delay due to hang issues seen in 5.7 with startup like --no-defaults --plugin-load=tokudb=ha_tokudb.so --tokudb-check-jemalloc=0 --init-file=/home/hrvoje/percona-qa/plugins_57.sql --binlog-group-commit-sync-delay=2047
EXCLUDED_LIST=( --basedir --datadir --plugin-dir --lc-messages-dir --tmpdir --slave-load-tmpdir --bind-address --binlog-checksum --character-sets-dir --init-file --general-log-file --log-error --innodb-data-home-dir --event-scheduler --chroot --init-slave --init-connect --debug --default-time-zone --des-key-file --ft-stopword-file --innodb-page-size --innodb-undo-tablespaces --innodb-data-file-path --innodb-ft-aux-table --innodb-ft-server-stopword-table --innodb-ft-user-stopword-table --innodb-log-arch-dir --innodb-log-group-home-dir --log-bin-index --relay-log-index --report-host --report-password --report-user --secure-file-priv --slave-skip-errors --ssl-ca --ssl-capath --ssl-cert --ssl-cipher --ssl-crl --ssl-crlpath --ssl-key --utility-user --utility-user-password --socket --socket-umask --innodb-trx-rseg-n-slots-debug --innodb-fil-make-page-dirty-debug --initialize --initialize-insecure --port --binlog-group-commit-sync-delay --innodb-directories --keyring-migration-destination --keyring-migration-host --keyring-migration-password --keyring-migration-port --keyring-migration-socket --keyring-migration-source --keyring-migration-user --mysqlx-socket --mysqlx-ssl-ca --mysqlx-bind-address --mysqlx-ssl-capath --mysqlx-ssl-cert --mysqlx-ssl-cipher --mysqlx-ssl-crl --mysqlx-ssl-crlpath --mysqlx-ssl-key )
# Create a file (${OUTPUT_FILE}) with all options/values intelligently handled and included
rm -Rf ${OUTPUT_FILE}
touch ${OUTPUT_FILE}

while read line; do 
  OPTION="--$(echo ${line} | awk '{print $1}')"
  VALUE="$(echo ${line} | awk '{print $2}' | sed 's|^[ \t]*||;s|[ \t]*$||')"
  if [ "${VALUE}" == "(No" ]; then
    echoit "Working on option '${OPTION}' which has no default value..."
  else
    echoit "Working on option '${OPTION}' with default value '${VALUE}'..."
  fi
  # Process options & values
  if [[ " ${EXCLUDED_LIST[@]} " =~ " ${OPTION} " ]]; then 
    echoit "  > Option '${OPTION}' is logically excluded from being handled by this script..."
  elif [ "${OPTION}" == "--enforce-storage-engine" ]; then
    echoit "  > Adding possible values InnoDB, MyISAM, TokuDB, CSV, MERGE, MEMORY, BLACKHOLE for option '${OPTION}' to the final list..."   # There are more...
    echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
    echo "${OPTION}=MyISAM" >> ${OUTPUT_FILE}
    echo "${OPTION}=TokuDB" >> ${OUTPUT_FILE}
    echo "${OPTION}=CSV" >> ${OUTPUT_FILE}
    echo "${OPTION}=MERGE" >> ${OUTPUT_FILE}
    echo "${OPTION}=MEMORY" >> ${OUTPUT_FILE}
    echo "${OPTION}=BLACKHOLE" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--binlog-error-action" ]; then
    echoit "  > Adding possible values IGNORE_ERROR, ABORT_SERVER for option '${OPTION}' to the final list..."
    echo "${OPTION}=IGNORE_ERROR" >> ${OUTPUT_FILE}
    echo "${OPTION}=ABORT_SERVER" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--enforce-gtid-consistency" ]; then
    echoit "  > Adding possible values OFF, ON, WARN for option '${OPTION}' to the final list..."
    echo "${OPTION}=OFF" >> ${OUTPUT_FILE}
    echo "${OPTION}=ON" >> ${OUTPUT_FILE}
    echo "${OPTION}=WARN" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--gtid-mode" ]; then
    echoit "  > Adding possible values OFF, OFF_PERMISSIVE, ON_PERMISSIVE, ON, ON enforce for option '${OPTION}' to the final list..."
    echo "${OPTION}=OFF" >> ${OUTPUT_FILE}
    echo "${OPTION}=OFF_PERMISSIVE" >> ${OUTPUT_FILE}
    echo "${OPTION}=ON" >> ${OUTPUT_FILE}
    echo "${OPTION}=ON --enforce-gtid-consistency=ON" >> ${OUTPUT_FILE}
    echo "${OPTION}=ON_PERMISSIVE" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--mandatory-roles" ]; then
    echoit "  > Adding possible values '','role1@%,role2,role3,role4@localhost','@%','user1@localhost,testuser@%' for option '${OPTION}' to the final list..."
    echo "${OPTION}=''" >> ${OUTPUT_FILE}
    echo "${OPTION}='role1@%,role2,role3,role4@localhost'" >> ${OUTPUT_FILE}
    echo "${OPTION}='@%'" >> ${OUTPUT_FILE}
    echo "${OPTION}='user1@localhost,testuser@%'" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--binlog-format" ]; then
    echoit "  > Adding possible values ROW, STATEMENT, MIXED for option '${OPTION}' to the final list..."
    echo "${OPTION}=ROW" >> ${OUTPUT_FILE}
    echo "${OPTION}=STATEMENT" >> ${OUTPUT_FILE}
    echo "${OPTION}=MIXED" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--binlog-row-image" ]; then
    echoit "  > Adding possible values full, minimal, noblob for option '${OPTION}' to the final list..."
    echo "${OPTION}=full" >> ${OUTPUT_FILE}
    echo "${OPTION}=minimal" >> ${OUTPUT_FILE}
    echo "${OPTION}=noblob" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--binlog-row-value-options" ]; then
    echoit "  > Adding possible values '',PARTIAL_JSON for option '${OPTION}' to the final list..."
    echo "${OPTION}=''" >> ${OUTPUT_FILE}
    echo "${OPTION}=PARTIAL_JSON" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--binlogging-impossible-mode" ]; then
    echoit "  > Adding possible values IGNORE_ERROR, ABORT_SERVER for option '${OPTION}' to the final list..."
    echo "${OPTION}=IGNORE_ERROR" >> ${OUTPUT_FILE}
    echo "${OPTION}=ABORT_SERVER" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--character-set-filesystem" -o "${OPTION}" == "--character-set-server" ]; then
    echoit "  > Adding possible values binary, utf8 for option '${OPTION}' to the final list..."
    echo "${OPTION}=binary" >> ${OUTPUT_FILE}
    echo "${OPTION}=utf8" >> ${OUTPUT_FILE}
    echo "${OPTION}=big5" >> ${OUTPUT_FILE}
    echo "${OPTION}=dec8" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp850" >> ${OUTPUT_FILE}
    echo "${OPTION}=hp8" >> ${OUTPUT_FILE}
    echo "${OPTION}=koi8r" >> ${OUTPUT_FILE}
    echo "${OPTION}=latin1" >> ${OUTPUT_FILE}
    echo "${OPTION}=latin2" >> ${OUTPUT_FILE}
    echo "${OPTION}=swe7" >> ${OUTPUT_FILE}
    echo "${OPTION}=ascii" >> ${OUTPUT_FILE}
    echo "${OPTION}=ujis" >> ${OUTPUT_FILE}
    echo "${OPTION}=sjis" >> ${OUTPUT_FILE}
    echo "${OPTION}=hebrew" >> ${OUTPUT_FILE}
    echo "${OPTION}=tis620" >> ${OUTPUT_FILE}
    echo "${OPTION}=euckr" >> ${OUTPUT_FILE}
    echo "${OPTION}=koi8u" >> ${OUTPUT_FILE}
    echo "${OPTION}=gb2312" >> ${OUTPUT_FILE}
    echo "${OPTION}=greek" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp1250" >> ${OUTPUT_FILE}
    echo "${OPTION}=gbk" >> ${OUTPUT_FILE}
    echo "${OPTION}=latin5" >> ${OUTPUT_FILE}
    echo "${OPTION}=armscii8" >> ${OUTPUT_FILE}
    echo "${OPTION}=ucs2" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp866" >> ${OUTPUT_FILE}
    echo "${OPTION}=keybcs2" >> ${OUTPUT_FILE}
    echo "${OPTION}=macce" >> ${OUTPUT_FILE}
    echo "${OPTION}=macroman" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp852" >> ${OUTPUT_FILE}
    echo "${OPTION}=latin7" >> ${OUTPUT_FILE}
    echo "${OPTION}=utf8mb4" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp1251" >> ${OUTPUT_FILE}
    echo "${OPTION}=utf16" >> ${OUTPUT_FILE}
    echo "${OPTION}=utf16le" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp1256" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp1257" >> ${OUTPUT_FILE}
    echo "${OPTION}=utf32" >> ${OUTPUT_FILE}
    echo "${OPTION}=geostd8" >> ${OUTPUT_FILE}
    echo "${OPTION}=cp932" >> ${OUTPUT_FILE}
    echo "${OPTION}=eucjpms" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--collation-server" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--completion-type" ]; then
    echoit "  > Adding possible values 0, 1, 2 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--concurrent-insert" ]; then
    echoit "  > Adding possible values 0, 1, 2 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--csv-mode" ]; then
    echoit "  > Adding possible values IETF_QUOTES for option '${OPTION}' to the final list..."
    echo "${OPTION}=IETF_QUOTES" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-slow-filter" ]; then
    echoit "  > Adding possible values qc_miss, full_scan for option '${OPTION}' to the final list..."
    echo "${OPTION}=qc_miss" >> ${OUTPUT_FILE}
    echo "${OPTION}=full_scan" >> ${OUTPUT_FILE}
    echo "${OPTION}=full_join" >> ${OUTPUT_FILE}
    echo "${OPTION}=tmp_table" >> ${OUTPUT_FILE}
    echo "${OPTION}=tmp_table_on_disk" >> ${OUTPUT_FILE}
    echo "${OPTION}=filesort" >> ${OUTPUT_FILE}
    echo "${OPTION}=filesort_on_disk" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-slow-verbosity" ]; then
    echoit "  > Adding possible values microtime, query_plan for option '${OPTION}' to the final list..."
    echo "${OPTION}=microtime" >> ${OUTPUT_FILE}
    echo "${OPTION}=query_plan" >> ${OUTPUT_FILE}
    echo "${OPTION}=innodb" >> ${OUTPUT_FILE}
    echo "${OPTION}=minimal" >> ${OUTPUT_FILE}
    echo "${OPTION}=standard" >> ${OUTPUT_FILE}
    echo "${OPTION}=full" >> ${OUTPUT_FILE}
    echo "${OPTION}=profiling" >> ${OUTPUT_FILE}
    echo "${OPTION}=profiling_use_getrusageg" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-log-files-in-group" ]; then
    echoit "  > Adding possible values 0,1,2,5,10 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
    echo "${OPTION}=5" >> ${OUTPUT_FILE}
    echo "${OPTION}=10" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-warnings-suppress" ]; then
    echoit "  > Adding possible values 1592 for option '${OPTION}' to the final list..."
    echo "${OPTION}=1592" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--slave-type-conversions" ]; then
    echoit "  > Adding possible values ALL_LOSSY, ALL_NON_LOSSY for option '${OPTION}' to the final list..."
    echo "${OPTION}=ALL_LOSSY" >> ${OUTPUT_FILE}
    echo "${OPTION}=ALL_NON_LOSSY" >> ${OUTPUT_FILE}
    echo "${OPTION}=ALL_SIGNED" >> ${OUTPUT_FILE}
    echo "${OPTION}=ALL_UNSIGNED" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-checksum-algorithm" ]; then
    echoit "  > Adding possible values innodb, crc32 for option '${OPTION}' to the final list..."
    echo "${OPTION}=innodb" >> ${OUTPUT_FILE}
    echo "${OPTION}=crc32" >> ${OUTPUT_FILE}
    echo "${OPTION}=none" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-cleaner-lsn-age-factor" ]; then
    echoit "  > Adding possible values legacy, high_checkpoint for option '${OPTION}' to the final list..."
    echo "${OPTION}=legacy" >> ${OUTPUT_FILE}
    echo "${OPTION}=high_checkpoint" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-corrupt-table-action" ]; then
    echoit "  > Adding possible values assert, warn for option '${OPTION}' to the final list..."
    echo "${OPTION}=assert" >> ${OUTPUT_FILE}
    echo "${OPTION}=warn" >> ${OUTPUT_FILE}
    echo "${OPTION}=salvage" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-empty-free-list-algorithm" ]; then
    echoit "  > Adding possible values legacy, backoff for option '${OPTION}' to the final list..."
    echo "${OPTION}=legacy" >> ${OUTPUT_FILE}
    echo "${OPTION}=backoff" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-file-format-max" ]; then
    echoit "  > Adding possible values Antelope, Barracuda for option '${OPTION}' to the final list..."
    echo "${OPTION}=Antelope" >> ${OUTPUT_FILE}
    echo "${OPTION}=Barracuda" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-foreground-preflush" ]; then
    echoit "  > Adding possible values sync_preflush, exponential_backoff for option '${OPTION}' to the final list..."
    echo "${OPTION}=sync_preflush" >> ${OUTPUT_FILE}
    echo "${OPTION}=exponential_backoff" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-buffer-pool-evict" ]; then
    echoit "  > Adding possible values uncompressed for option '${OPTION}' to the final list..."
    echo "${OPTION}=uncompressed" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-flush-method" ]; then
    echoit "  > Adding possible values fsync, O_DSYNC for option '${OPTION}' to the final list..."
    echo "${OPTION}=fsync" >> ${OUTPUT_FILE}
    echo "${OPTION}=O_DSYNC" >> ${OUTPUT_FILE}
    echo "${OPTION}=O_DIRECT" >> ${OUTPUT_FILE}
    echo "${OPTION}=O_DIRECT_NO_FSYNC" >> ${OUTPUT_FILE}
    echo "${OPTION}=littlesync" >> ${OUTPUT_FILE}
    echo "${OPTION}=nosync" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-log-checksum-algorithm" ]; then
    echoit "  > Adding possible values innodb, crc32 for option '${OPTION}' to the final list..."
    echo "${OPTION}=innodb" >> ${OUTPUT_FILE}
    echo "${OPTION}=crc32" >> ${OUTPUT_FILE}
    echo "${OPTION}=none" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-monitor-disable" ]; then
    echoit "  > Adding possible values counter, module for option '${OPTION}' to the final list..."
    echo "${OPTION}=counter" >> ${OUTPUT_FILE}
    echo "${OPTION}=module" >> ${OUTPUT_FILE}
    echo "${OPTION}=pattern" >> ${OUTPUT_FILE}
    echo "${OPTION}=all" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-monitor-enable" ]; then
    echoit "  > Adding possible values counter, module for option '${OPTION}' to the final list..."
    echo "${OPTION}=counter" >> ${OUTPUT_FILE}
    echo "${OPTION}=module" >> ${OUTPUT_FILE}
    echo "${OPTION}=pattern" >> ${OUTPUT_FILE}
    echo "${OPTION}=all" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-monitor-reset" ]; then
    echoit "  > Adding possible values counter, module for option '${OPTION}' to the final list..."
    echo "${OPTION}=counter" >> ${OUTPUT_FILE}
    echo "${OPTION}=module" >> ${OUTPUT_FILE}
    echo "${OPTION}=pattern" >> ${OUTPUT_FILE}
    echo "${OPTION}=all" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-monitor-reset-all" ]; then
    echoit "  > Adding possible values counter, module for option '${OPTION}' to the final list..."
    echo "${OPTION}=counter" >> ${OUTPUT_FILE}
    echo "${OPTION}=module" >> ${OUTPUT_FILE}
    echo "${OPTION}=pattern" >> ${OUTPUT_FILE}
    echo "${OPTION}=all" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-stats-method" ]; then
    echoit "  > Adding possible values nulls_equal, nulls_unequal for option '${OPTION}' to the final list..."
    echo "${OPTION}=nulls_equal" >> ${OUTPUT_FILE}
    echo "${OPTION}=nulls_unequal" >> ${OUTPUT_FILE}
    echo "${OPTION}=nulls_ignored" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-bin" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
    echo "${OPTION}" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-slow-rate-type" ]; then
    echoit "  > Adding possible values session, query for option '${OPTION}' to the final list..."
    echo "${OPTION}=session" >> ${OUTPUT_FILE}
    echo "${OPTION}=query" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--myisam-stats-method" ]; then
    echoit "  > Adding possible values nulls_equal, nulls_unequal for option '${OPTION}' to the final list..."
    echo "${OPTION}=nulls_equal" >> ${OUTPUT_FILE}
    echo "${OPTION}=nulls_unequal" >> ${OUTPUT_FILE}
    echo "${OPTION}=nulls_ignored" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--performance-schema-accounts-size" ]; then
    echoit "  > Adding possible values 0, 1, 2, 12, 24, 254, 1023, 2047, 1048576 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
    echo "${OPTION}=12" >> ${OUTPUT_FILE}
    echo "${OPTION}=24" >> ${OUTPUT_FILE}
    echo "${OPTION}=254" >> ${OUTPUT_FILE}
    echo "${OPTION}=1023" >> ${OUTPUT_FILE}
    echo "${OPTION}=2047" >> ${OUTPUT_FILE}
    echo "${OPTION}=1048576" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--performance-schema-hosts-size" ]; then
    echoit "  > Adding possible values 0, 1, 2, 12, 24, 254, 1023, 2047, 1048576 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
    echo "${OPTION}=12" >> ${OUTPUT_FILE}
    echo "${OPTION}=24" >> ${OUTPUT_FILE}
    echo "${OPTION}=254" >> ${OUTPUT_FILE}
    echo "${OPTION}=1023" >> ${OUTPUT_FILE}
    echo "${OPTION}=2047" >> ${OUTPUT_FILE}
    echo "${OPTION}=1048576" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--performance-schema-max-thread-instances" ]; then
    echoit "  > Adding possible values 0, 1, 2, 12, 24, 254, 1023, 2047, 104857 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
    echo "${OPTION}=12" >> ${OUTPUT_FILE}
    echo "${OPTION}=24" >> ${OUTPUT_FILE}
    echo "${OPTION}=254" >> ${OUTPUT_FILE}
    echo "${OPTION}=1023" >> ${OUTPUT_FILE}
    echo "${OPTION}=2047" >> ${OUTPUT_FILE}
    echo "${OPTION}=104857" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--performance-schema-users-size" ]; then
    echoit "  > Adding possible values 0, 1, 2, 12, 24, 254, 1023, 2047, 104857 for option '${OPTION}' to the final list..."
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
    echo "${OPTION}=12" >> ${OUTPUT_FILE}
    echo "${OPTION}=24" >> ${OUTPUT_FILE}
    echo "${OPTION}=254" >> ${OUTPUT_FILE}
    echo "${OPTION}=1023" >> ${OUTPUT_FILE}
    echo "${OPTION}=2047" >> ${OUTPUT_FILE}
    echo "${OPTION}=104857" >> ${OUTPUT_FILE} 
  elif [ "${OPTION}" == "--relay-log" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
    echo "${OPTION}" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--slow-query-log-timestamp-precision" ]; then
    echoit "  > Adding possible values second, microsecond for option '${OPTION}' to the final list..."
    echo "${OPTION}=second" >> ${OUTPUT_FILE}
    echo "${OPTION}=microsecond" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--slow-query-log-use-global-control" ]; then
    echoit "  > Adding possible values none, log_slow_filter, log_slow_rate_limit for option '${OPTION}' to the final list..."
    echo "${OPTION}=none" >> ${OUTPUT_FILE}
    echo "${OPTION}=log_slow_filter" >> ${OUTPUT_FILE}
    echo "${OPTION}=log_slow_rate_limit" >> ${OUTPUT_FILE}
    echo "${OPTION}=log_slow_verbosity" >> ${OUTPUT_FILE}
    echo "${OPTION}=long_query_time" >> ${OUTPUT_FILE}
    echo "${OPTION}=min_examined_row_limit" >> ${OUTPUT_FILE}
    echo "${OPTION}=all" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--sql-mode" ]; then
    echoit "  > Adding possible values ALLOW_INVALID_DATES, ANSI_QUOTES for option '${OPTION}' to the final list..."
    echo "${OPTION}=ALLOW_INVALID_DATES" >> ${OUTPUT_FILE}
    echo "${OPTION}=ANSI_QUOTES" >> ${OUTPUT_FILE}
    echo "${OPTION}=ERROR_FOR_DIVISION_BY_ZERO" >> ${OUTPUT_FILE}
    echo "${OPTION}=HIGH_NOT_PRECEDENCE" >> ${OUTPUT_FILE}
    echo "${OPTION}=IGNORE_SPACE" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_AUTO_CREATE_USER" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_AUTO_VALUE_ON_ZERO" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_BACKSLASH_ESCAPES" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_DIR_IN_CREATE" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_ENGINE_SUBSTITUTION" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_FIELD_OPTIONS" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_KEY_OPTIONS" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_TABLE_OPTIONS" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_UNSIGNED_SUBTRACTION" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_ZERO_DATE" >> ${OUTPUT_FILE}
    echo "${OPTION}=NO_ZERO_IN_DATE" >> ${OUTPUT_FILE}
    echo "${OPTION}=ONLY_FULL_GROUP_BY" >> ${OUTPUT_FILE}
    echo "${OPTION}=PAD_CHAR_TO_FULL_LENGTH" >> ${OUTPUT_FILE}
    echo "${OPTION}=PIPES_AS_CONCAT" >> ${OUTPUT_FILE}
    echo "${OPTION}=REAL_AS_FLOAT" >> ${OUTPUT_FILE}
    echo "${OPTION}=STRICT_ALL_TABLES" >> ${OUTPUT_FILE}
    echo "${OPTION}=STRICT_TRANS_TABLES" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--thread-handling" ]; then
    echoit "  > Adding possible values no-threads, one-thread-per-connection for option '${OPTION}' to the final list..."
    echo "${OPTION}=no-threads" >> ${OUTPUT_FILE}
    echo "${OPTION}=one-thread-per-connection" >> ${OUTPUT_FILE}
    echo "${OPTION}=dynamically-loaded" >> ${OUTPUT_FILE}
    echo "${OPTION}=pool-of-threads" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--thread-pool-high-prio-mode" ]; then
    echoit "  > Adding possible values transactions, statements for option '${OPTION}' to the final list..."
    echo "${OPTION}=transactions" >> ${OUTPUT_FILE}
    echo "${OPTION}=statements" >> ${OUTPUT_FILE}
    echo "${OPTION}=none" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--transaction-isolation" ]; then
    echoit "  > Adding possible values READ-UNCOMMITTED, READ-COMMITTED for option '${OPTION}' to the final list..."
    echo "${OPTION}=READ-UNCOMMITTED" >> ${OUTPUT_FILE}
    echo "${OPTION}=READ-COMMITTED" >> ${OUTPUT_FILE}
    echo "${OPTION}=REPEATABLE-READ" >> ${OUTPUT_FILE}
    echo "${OPTION}=SERIALIZABLE" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--utility-user-schema-access" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--utility-user-privileges" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--proxy-protocol-networks" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--disabled-storage-engines" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--innodb-temp-data-file-path" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--innodb-undo-directory" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--log-syslog-tag" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--innodb-doublewrite-file" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--plugin-load" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--sql-mode" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--innodb-monitor-gaplock-query-filename" ]; then                  ## fb-mysql
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--innodb-tmpdir" ]; then                                          ## fb-mysql
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--rocksdb-compact-cf" ]; then                                     ## fb-mysql
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--rocksdb-default-cf-options" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--rocksdb-override-cf-options" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--rocksdb-snapshot-dir" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--rocksdb-strict-collation-exceptions" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--rocksdb-wal-dir" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--optimizer-trace" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--performance-schema-instrument" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--block-encryption-mode" ]; then
    echoit "  > Adding possible values aes-128-ecb, aes-128-cbc, aes-128-cfb1, aes-192-ecb, aes-192-cbc, aes-192-ofb, aes-256-ecb, aes-256-cbc, aes-256-cfb128 for option '${OPTION}' to the final list..."
    echo "${OPTION}=aes-128-ecb" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-128-cbc" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-128-cfb1" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-192-ecb" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-192-cbc" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-192-ofb" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-256-ecb" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-256-cbc" >> ${OUTPUT_FILE}
    echo "${OPTION}=aes-256-cfb128" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--tokudb_cache_size" ]; then
    echoit "  > Adding possible values 52428800, 1125899906842624 for option '${OPTION}' to the final list..."
    echo "${OPTION}=52428800" >> ${OUTPUT_FILE}
    echo "${OPTION}==1125899906842624" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--default-authentication-plugin" ]; then
    echoit "  > Adding possible values mysql_native_password, sha256_password for option '${OPTION}' to the final list..."
    echo "${OPTION}=mysql_native_password" >> ${OUTPUT_FILE}
    echo "${OPTION}=sha256_password" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-change-buffering" ]; then
    echoit "  > Adding possible values all, none, inserts, deletes, changes, purges for option '${OPTION}' to the final list..."
    echo "${OPTION}=all" >> ${OUTPUT_FILE}
    echo "${OPTION}=none" >> ${OUTPUT_FILE}
    echo "${OPTION}=inserts" >> ${OUTPUT_FILE}
    echo "${OPTION}=deletes" >> ${OUTPUT_FILE}
    echo "${OPTION}=changes" >> ${OUTPUT_FILE}
    echo "${OPTION}=purges" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--innodb-default-row-format" ]; then
    echoit "  > Adding possible values dynamic, compact, redundant for option '${OPTION}' to the final list..."
    echo "${OPTION}=dynamic" >> ${OUTPUT_FILE}
    echo "${OPTION}=compact" >> ${OUTPUT_FILE}
    echo "${OPTION}=redundant" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--internal-tmp-disk-storage-engine" ]; then
    echoit "  > Adding possible values INNODB, MYISAM for option '${OPTION}' to the final list..."
    echo "${OPTION}=INNODB" >> ${OUTPUT_FILE}
    echo "${OPTION}=MYISAM" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-output" ]; then
    echoit "  > Adding possible values FILE, TABLE, NONE for option '${OPTION}' to the final list..."
    echo "${OPTION}=FILE" >> ${OUTPUT_FILE}
    echo "${OPTION}=TABLE" >> ${OUTPUT_FILE}
    echo "${OPTION}=NONE" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--log-timestamps" ]; then
    echoit "  > Adding possible values SYSTEM, UTC for option '${OPTION}' to the final list..."
    echo "${OPTION}=UTC" >> ${OUTPUT_FILE}
    echo "${OPTION}=SYSTEM" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--master-info-repository" ]; then
    echoit "  > Adding possible values FILE, TABLE for option '${OPTION}' to the final list..."
    echo "${OPTION}=FILE" >> ${OUTPUT_FILE}
    echo "${OPTION}=TABLE" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--relay-log-info-repository" ]; then
    echoit "  > Adding possible values FILE, TABLE for option '${OPTION}' to the final list..."
    echo "${OPTION}=FILE" >> ${OUTPUT_FILE}
    echo "${OPTION}=TABLE" >> ${OUTPUT_FILE}
  elif [ "${OPTION}" == "--default-storage-engine" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
    if [[ $IS_PXC -eq 1 ]]; then 
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}   # More times InnoDB to increase random selection frequency
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=MEMORY" >> ${OUTPUT_FILE}
      echo "${OPTION}=MyISAM" >> ${OUTPUT_FILE}
      echo "${OPTION}=TokuDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=RocksDB" >> ${OUTPUT_FILE}
    else
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}   # More times InnoDB to increase random selection frequency
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=InnoDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=MEMORY" >> ${OUTPUT_FILE}
      echo "${OPTION}=MEMORY" >> ${OUTPUT_FILE}
      echo "${OPTION}=MyISAM" >> ${OUTPUT_FILE}
      echo "${OPTION}=TokuDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=TokuDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=TokuDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=RocksDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=RocksDB" >> ${OUTPUT_FILE}
      echo "${OPTION}=RocksDB" >> ${OUTPUT_FILE}
    fi
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${OPTION}" == "--" ]; then
    echoit "  > Adding possible values ... for option '${OPTION}' to the final list..."
  elif [ "${VALUE}" == "TRUE" -o "${VALUE}" == "FALSE" -o "${VALUE}" == "ON" -o "${VALUE}" == "OFF" -o "${VALUE}" == "YES" -o "${VALUE}" == "NO" ]; then
    echoit "  > Adding possible values TRUE/ON/YES/1 and FALSE/OFF/NO/0 (as a universal 1 and 0) for option '${OPTION}' to the final list..."
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
  elif [[ "$(echo ${VALUE} | tr -d ' ')" =~ ^-?[0-9]+$ ]]; then
  #elif [[ "$(echo ${VALUE} | tr -d ' ' | tr -d '-')" =~ ^[0-9]+$ ]]; then
  #elif [[ ${VALUE} =~ ^-?[0-9]+$ ]]; then
  #elif [ "$(echo ${VALUE} | sed 's|[0-9]||g')" == "" -a "$(echo ${VALUE} | sed 's|[^0-9]||g')" != "" ]; then  # Fully numerical
    if [ "${VALUE}" != "0" ]; then 
      echoit "  > Adding int values (${VALUE}, -1, 0, 1, 2, 12, 24, 254, 1023, 2047, -1125899906842624, 1125899906842624) for option '${OPTION}' to the final list..."
      echo "${OPTION}=${VALUE}" >> ${OUTPUT_FILE}
    else
      echoit "  > Adding int values (-1, 0, 1, 2, 12, 24, 254, 1023, 2047, -1125899906842624, 1125899906842624) for option '${OPTION}' to the final list..."
    fi
    echo "${OPTION}=0" >> ${OUTPUT_FILE}
    echo "${OPTION}=1" >> ${OUTPUT_FILE}
    echo "${OPTION}=2" >> ${OUTPUT_FILE}
    echo "${OPTION}=12" >> ${OUTPUT_FILE}
    echo "${OPTION}=24" >> ${OUTPUT_FILE}
    echo "${OPTION}=254" >> ${OUTPUT_FILE}
    echo "${OPTION}=1023" >> ${OUTPUT_FILE}
    echo "${OPTION}=2047" >> ${OUTPUT_FILE}
    echo "${OPTION}=-1125899906842624" >> ${OUTPUT_FILE}
    echo "${OPTION}=1125899906842624" >> ${OUTPUT_FILE}
  elif [ "${VALUE}" == "" -o "${VALUE}" == "(No" ]; then
    echoit "  > Assert: Option '${OPTION}' is blank by default and not programmed into the script yet, please cover this in the script..."
    exit 1
  else
    echoit "  > ${OPTION} IS NOT COVERED YET, PLEASE ADD!!!"
    #exit 1
  fi
done < ${TEMP_FILE}
rm -Rf ${TEMP_FILE}

echo "Done! Output file: ${OUTPUT_FILE}"
