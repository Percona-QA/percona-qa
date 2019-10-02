set -eu

prepare_environment() {
  mkdir -p ${TEST_RESULT_DIR}
}

start_replica() {
  vlog "Starting replica set rs1"
  ${PQA_PATH}/mongo_startup.sh --rSet --pbmDir=${PBM_PATH} --storageEngine=${STORAGE_ENGINE} --auth --binDir=${MONGODB_PATH}/bin --workDir=${TEST_RESULT_DIR}/var/w$worker/nodes --host=${HOST} ${EXTRA_STARTUP_OPTS}
  run_cmd ${TEST_RESULT_DIR}/var/w$worker/nodes/pbm_store_set.sh
}

start_sharding_cluster() {
  vlog "Starting sharding cluster"
  ${PQA_PATH}/mongo_startup.sh --sCluster --pbmDir=${PBM_PATH} --storageEngine=${STORAGE_ENGINE} --auth --binDir=${MONGODB_PATH}/bin --workDir=${TEST_RESULT_DIR}/var/w$worker/nodes --host=${HOST} ${EXTRA_STARTUP_OPTS}
  run_cmd ${TEST_RESULT_DIR}/var/w$worker/nodes/pbm_store_set.sh
}

stop_all_mongo() {
  vlog "Stopping all mongodb processes"
  ${TEST_RESULT_DIR}/var/w$worker/nodes/stop_mongodb.sh
}

stop_all_pbm() {
  vlog "Stopping all PBM processes"
  ${TEST_RESULT_DIR}/var/w$worker/nodes/stop_pbm.sh
}

run_backup() {
  run_cmd pbm backup --mongodb-uri="${MONGODB_URI}${MONGODB_OPTS}" | tee ${TEST_RESULT_DIR}/var/w$worker/nodes/last_backup_id
}

run_restore() {
  local BACKUP_ID_TO_RESTORE=$1
  run_cmd pbm restore --mongodb-uri="${MONGODB_URI}${MONGODB_OPTS}" ${BACKUP_ID_TO_RESTORE}
}

get_last_backup_id() {
  cat ${TEST_RESULT_DIR}/var/w$worker/nodes/last_backup_id | tail -n1 | cut -d' ' -f3 | sed 's/'\''//g'
}

get_last_backup_status() {
  local BACKUP_ID=$(get_last_backup_id)
  run_cmd mongo ${MONGODB_URI}${MONGODB_OPTS} --eval "db.getSiblingDB('admin').pbmBackups.findOne({ name: \"${BACKUP_ID}\" }).status" --quiet | tail -n1
}

get_operation_count() {
  run_cmd mongo ${MONGODB_URI}${MONGODB_OPTS} --eval "db.getSiblingDB('admin').pbmOp.count()" --quiet | tail -n1
}

wait_backup_finish() {
  local TIMEOUT=${1:-300}
  local BACKUP_STATUS=""
  local TIMEOUT_COUNTER=0
  while true; do
    sleep 1
    BACKUP_STATUS=$(get_last_backup_status)
    TIMEOUT_COUNTER=$((TIMEOUT_COUNTER+1))
    if [ "${BACKUP_STATUS}" == "done" ]; then
      vlog "Backup has finished."
      break
    elif [ ${TIMEOUT_COUNTER} -eq ${TIMEOUT} ]; then
      die "Backup didn't finish, timeout reached."
      break
    fi
  done
}

wait_restore_finish() {
  local TIMEOUT=${1:-300}
  local RESTORE_STATUS=0
  local TIMEOUT_COUNTER=0
  while true; do
    sleep 1
    RESTORE_STATUS=$(get_operation_count)
    TIMEOUT_COUNTER=$((TIMEOUT_COUNTER+1))
    if [ ${RESTORE_STATUS} -eq 0 ]; then
      vlog "Restore has finished."
      break
    elif [ ${TIMEOUT_COUNTER} -eq ${TIMEOUT} ]; then
      die "Restore didn't finish, timeout reached."
      break
    fi
  done
}

start_pbm_agent() {
  local AGENT_DIR="$1"
  vlog "Starting PBM agent in dir ${AGENT_DIR}..."
  run_cmd ${TEST_RESULT_DIR}/var/w$worker/nodes/${AGENT_DIR}/pbm-agent/start_pbm_agent.sh
}

stop_pbm_agent() {
  local AGENT_DIR="$1"
  vlog "Stopping PBM agent in dir ${AGENT_DIR}..."
  run_cmd ${TEST_RESULT_DIR}/var/w$worker/nodes/${AGENT_DIR}/pbm-agent/stop_pbm_agent.sh
}

get_replica_primary() {
  local HOST=$1
  local PORT=$2
  mongo --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --eval 'rs.isMaster().primary' --host=${HOST} --port=${PORT} --quiet|tail -n1
}

log_status() {
  local LOG_FILE="$1"
  local CLUSTER_TYPE="$2"
  local PRIMARY=""
  echo "##### DATABASES LIST #####" >> ${LOG_FILE}
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand( { listDatabases: 1 } )' --quiet >> ${LOG_FILE}
  echo "##### ADMIN DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "##### YCSB_TEST1 DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "db.usertable.count()" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "##### YCSB_TEST2 DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "db.usertable.count()" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "##### YCSB_TEST3 DATABASE USER AND ROLES COUNT #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "db.usertable.count()" >> ${LOG_FILE}
  mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "##### DATAGEN_IT_TEST DATABASE COLLECTION COUNTS #####" >> ${LOG_FILE}
  echo "db.test_bson.count()" >> ${LOG_FILE}
  mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_bson.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "db.test_agg.count()" >> ${LOG_FILE}
  mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "db.test_agg_data.count()" >> ${LOG_FILE}
  mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg_data.count()' --quiet | tail -n1 >> ${LOG_FILE}
  if [ "${CLUSTER_TYPE}" == "sharding" ]; then
    PRIMARY=$(get_replica_primary localhost 27018)
    echo "##### YCSB_TEST1 DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST2 DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST3 DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### DATAGEN_IT_TEST DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    PRIMARY=$(get_replica_primary localhost 28018)
    echo "##### YCSB_TEST1 DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST2 DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST3 DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### DATAGEN_IT_TEST DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### SHARDING STATUS #####" >> ${LOG_FILE}
    mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.status()' --quiet >> ${LOG_FILE}
  else
    echo "##### YCSB_TEST1 DATABASE MD5 #####" >> ${LOG_FILE}
    mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST2 DATABASE MD5 #####" >> ${LOG_FILE}
    mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST3 DATABASE MD5 #####" >> ${LOG_FILE}
    mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
    echo "##### DATAGEN_IT_TEST DATABASE MD5 #####" >> ${LOG_FILE}
    mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
  fi
}

check_cleanup() {
  if [ "$(mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUser("tomislav_admin")' --quiet|tail -n1)" != "null" ]; then
    die "Cleanup not completed fully! admin contains tomislav_admin user."
  elif [ "$(mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRole("myCustomAdminRole")' --quiet|tail -n1)" != "null" ]; then
    die "Cleanup not completed fully! admin contains myCustomAdminRole."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test1 contains collections."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUsers().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test1 contains users."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRoles().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test1 contains roles."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test2 contains collections."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUsers().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test2 contains users."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRoles().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test2 contains roles."
  elif [ "$(mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! ycsb_test3 contains collections."
  elif [ "$(mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    die "Cleanup not completed fully! datagen_it_test contains collections."
  fi
}

cleanup() {
  vlog "Data cleanup"
  # drop users
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.dropUser("tomislav_admin");' --quiet
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.dropUser("tomislav");' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.dropUser("ivana");' --quiet
  # drop roles
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.dropRole("myCustomAdminRole")' --quiet
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.dropRole("myCustomRole1")' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.dropRole("myCustomRole2")' --quiet
  # drop user databases
  run_cmd mongo ${MONGODB_URI}${MONGODB_OPTS} --eval 'db.getMongo().getDBNames().forEach(function(i){ if (i != "admin" && i != "local" && i != "config") { db.getSiblingDB(i).dropDatabase() } })' --quiet
#  stop_all_pbm
#  stop_all_mongo
#  sleep 5
#  rm -rf ${TEST_RESULT_DIR}/var/w$worker/pbm-test-temp
#  mv ${TEST_RESULT_DIR}/var/w$worker/nodes ${TEST_RESULT_DIR}/var/w$worker/pbm-test-temp
#  if [ "$1" == "sharding" ]; then
#    start_sharding_cluster
#  else
#    start_replica
#  fi
#  sleep 10
#  mv ${TEST_RESULT_DIR}/var/w$worker/pbm-test-temp/backup ${TEST_RESULT_DIR}/var/w$worker/nodes
#  mv ${TEST_RESULT_DIR}/var/w$worker/pbm-test-temp/pbm-coordinator/workdir ${TEST_RESULT_DIR}/var/w$worker/nodes/pbm-coordinator
#  if [ ${SAVE_STATE_BEFORE_RESTORE} -eq 0 ]; then
#    rm -rf ${TEST_RESULT_DIR}/var/w$worker/pbm-test-temp
#  fi
}

prepare_data() {
  vlog "Preparing data"
  # create databases/collections
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.createCollection("usertable")' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.createCollection("usertable")' --quiet
  if [ "$1" == "sharding" ]; then
    mgodatagen --file=${TEST_BASEDIR}/mgodatagen.json --host=${HOST} --port=27017 --username=${MONGODB_USER} --password=${MONGODB_PASS}
  else
    PRIMARY=$(get_replica_primary ${HOST} 27017 | cut -d':' -f2)
    mgodatagen --file=${TEST_BASEDIR}/mgodatagen.json --host=${HOST} --port=${PRIMARY} --username=${MONGODB_USER} --password=${MONGODB_PASS}
  fi
  # create roles
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.createRole({ role: "myCustomAdminRole", privileges: [{ resource: { db: "ycsb_test1", collection: "" }, actions: [ "find", "update", "insert", "remove" ] }], roles: [{ role: "root", db: "admin" }]}, { w: "majority" , wtimeout: 5000 })' --quiet
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.createRole({ role: "myCustomRole1", privileges: [{ resource: { db: "ycsb_test1", collection: "" }, actions: [ "find", "update", "insert", "remove" ] }], roles: [ ]}, { w: "majority" , wtimeout: 5000 })' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.createRole({ role: "myCustomRole2", privileges: [{ resource: { db: "ycsb_test2", collection: "" }, actions: [ "find", "update", "insert", "remove" ] }], roles: [ ]}, { w: "majority" , wtimeout: 5000 })' --quiet
  # create users
  mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.createUser({user: "tomislav_admin", pwd: "test12345", roles: [ "myCustomAdminRole" ] });' --quiet
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.createUser({user: "tomislav", pwd: "test12345", roles: [ "myCustomRole1" ] });' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.createUser({user: "ivana", pwd: "test12345", roles: [ "myCustomRole2" ] });' --quiet
  # add indexes
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field1: 1, field2: -1 })' --quiet
  mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field3: -1, field4: 1 })' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field1: 1, field2: -1 })' --quiet
  mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field3: -1, field4: 1 })' --quiet
  # insert data
  ycsb load mongodb -s -P ${YCSB_PATH}/workloads/workloadb -p recordcount=10000 -p operationcount=10000 -threads 8 -p mongodb.url="${MONGODB_URI}ycsb_test1${MONGODB_OPTS}" -p mongodb.auth="true"
  ycsb load mongodb -s -P ${YCSB_PATH}/workloads/workloadb -p recordcount=500000 -p operationcount=500000 -threads 8 -p mongodb.url="${MONGODB_URI}ycsb_test2${MONGODB_OPTS}" -p mongodb.auth="true"
  sleep 10
}

get_hashes_counts_before() {
  vlog "Get DB hashes and document counts before restore"
  # for sharding dbHash doesn't work on mongos and we need to get hashes from all shards
  if [ "$1" == "sharding" ]; then
    local PRIMARY=""
    PRIMARY=$(get_replica_primary ${HOST} 27018)
    local RS1_YCSB_TEST1_TEMP=$(mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS1_YCSB_TEST2_TEMP=$(mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS1_YCSB_TEST3_TEMP=$(mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:27018,localhost:27019,localhost:27020/ycsb_test3?replicaSet=rs1&authSource=admin" --collection usertable --type csv --sort '{_id: 1}' --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs1-oplog-export-before.csv
    local RS1_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs1-oplog-export-before.csv|cut -d' ' -f1)
    local RS1_DATAGEN_TEMP=$(mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    PRIMARY=$(get_replica_primary ${HOST} 28018)
    local RS2_YCSB_TEST1_TEMP=$(mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS2_YCSB_TEST2_TEMP=$(mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS2_YCSB_TEST3_TEMP=$(mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:28018,localhost:28019,localhost:28020/ycsb_test3?replicaSet=rs2&authSource=admin" --collection usertable --type csv --sort '{_id: 1}' --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs2-oplog-export-before.csv
    local RS2_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs2-oplog-export-before.csv|cut -d' ' -f1)
    local RS2_DATAGEN_TEMP=$(mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    YCSB_TEST1_MD5_INITIAL="${RS1_YCSB_TEST1_TEMP}+${RS2_YCSB_TEST1_TEMP}"
    YCSB_TEST2_MD5_INITIAL="${RS1_YCSB_TEST2_TEMP}+${RS2_YCSB_TEST2_TEMP}"
    YCSB_TEST3_MD5_INITIAL="${RS1_YCSB_TEST3_TEMP}+${RS2_YCSB_TEST3_TEMP}"
    DATAGEN_MD5_INITIAL="${RS1_DATAGEN_TEMP}+${RS2_DATAGEN_TEMP}"
  else
    YCSB_TEST1_MD5_INITIAL=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    YCSB_TEST2_MD5_INITIAL=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    #YCSB_TEST3_MD5_INITIAL=$(mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    mongoexport --uri=${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --collection usertable --type csv --sort '{_id: 1}' --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-oplog-export-before.csv
    YCSB_TEST3_MD5_INITIAL=$(md5sum -b ${TEST_DIR}/ycsb_test3-oplog-export-before.csv|cut -d' ' -f1)
    DATAGEN_MD5_INITIAL=$(mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  fi
  YCSB_TEST1_INITIAL_COUNT=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST2_INITIAL_COUNT=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST3_INITIAL_COUNT=$(mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
}

get_hashes_counts_after() {
  echo "Get DB hashes and document counts after restore"
  # for sharding dbHash doesn't work on mongos and we need to get hashes from all shards
  if [ "$1" == "sharding" ]; then
    local PRIMARY=""
    PRIMARY=$(get_replica_primary ${HOST} 27018)
    local RS1_YCSB_TEST1_TEMP=$(mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS1_YCSB_TEST2_TEMP=$(mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS1_YCSB_TEST3_TEMP=$(mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:27018,localhost:27019,localhost:27020/ycsb_test3?replicaSet=rs1&authSource=admin" --collection usertable --type csv --sort '{_id: 1}' --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs1-oplog-export-after.csv
    local RS1_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs1-oplog-export-after.csv|cut -d' ' -f1)
    local RS1_DATAGEN_TEMP=$(mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    PRIMARY=$(get_replica_primary ${HOST} 28018)
    local RS2_YCSB_TEST1_TEMP=$(mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS2_YCSB_TEST2_TEMP=$(mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS2_YCSB_TEST3_TEMP=$(mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:28018,localhost:28019,localhost:28020/ycsb_test3?replicaSet=rs2&authSource=admin" --collection usertable --type csv --sort '{_id: 1}' --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs2-oplog-export-after.csv
    local RS2_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs2-oplog-export-after.csv|cut -d' ' -f1)
    local RS2_DATAGEN_TEMP=$(mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    YCSB_TEST1_MD5_RESTORED="${RS1_YCSB_TEST1_TEMP}+${RS2_YCSB_TEST1_TEMP}"
    YCSB_TEST2_MD5_RESTORED="${RS1_YCSB_TEST2_TEMP}+${RS2_YCSB_TEST2_TEMP}"
    YCSB_TEST3_MD5_RESTORED="${RS1_YCSB_TEST3_TEMP}+${RS2_YCSB_TEST3_TEMP}"
    DATAGEN_MD5_RESTORED="${RS1_DATAGEN_TEMP}+${RS2_DATAGEN_TEMP}"
  else
    YCSB_TEST1_MD5_RESTORED=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    YCSB_TEST2_MD5_RESTORED=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    #YCSB_TEST3_MD5_RESTORED=$(mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    mongoexport --uri=${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --collection usertable --type csv --sort '{_id: 1}' --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-oplog-export-after.csv
    YCSB_TEST3_MD5_RESTORED=$(md5sum -b ${TEST_DIR}/ycsb_test3-oplog-export-after.csv|cut -d' ' -f1)
    DATAGEN_MD5_RESTORED=$(mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  fi
  YCSB_TEST1_RESTORED_COUNT=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST2_RESTORED_COUNT=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST3_RESTORED_COUNT=$(mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST1_RESTORED_INDEX_COUNT=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.getIndexes().length' --quiet|tail -n1)
  YCSB_TEST2_RESTORED_INDEX_COUNT=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.getIndexes().length' --quiet|tail -n1)
  ADMIN_ROLE_RESTORED=$(mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRole("myCustomAdminRole").db' --quiet|tail -n1)
  ADMIN_USER_RESTORED=$(mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUser("tomislav_admin").roles[0].role' --quiet|tail -n1)
  YCSB_TEST1_ROLE_RESTORED=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRole("myCustomRole1").db' --quiet|tail -n1)
  YCSB_TEST1_USER_RESTORED=$(mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUser("tomislav").roles[0].role' --quiet|tail -n1)
  YCSB_TEST2_ROLE_RESTORED=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRole("myCustomRole2").db' --quiet|tail -n1)
  YCSB_TEST2_USER_RESTORED=$(mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUser("ivana").roles[0].role' --quiet|tail -n1)
  DATAGEN_TEST_BSON_RESTORED_COUNT=$(mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_bson.count()' --quiet|tail -n1)
  DATAGEN_TEST_AGG_RESTORED_COUNT=$(mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg.count()' --quiet|tail -n1)
  DATAGEN_TEST_AGG_DATA_RESTORED_COUNT=$(mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg_data.count()' --quiet|tail -n1)
}

check_after_restore() {
  vlog "Doing checks after restore"
  if [ "${YCSB_TEST1_MD5_INITIAL}" != "${YCSB_TEST1_MD5_RESTORED}" ]; then
    die "ycsb_test1 database md5 doesn't match: ${YCSB_TEST1_MD5_INITIAL} != ${YCSB_TEST1_MD5_RESTORED}"
  elif [ "${YCSB_TEST2_MD5_INITIAL}" != "${YCSB_TEST2_MD5_RESTORED}" ]; then
    die "ycsb_test2 database md5 doesn't match: ${YCSB_TEST2_MD5_INITIAL} != ${YCSB_TEST2_MD5_RESTORED}"
  elif [ "${YCSB_TEST3_MD5_INITIAL}" != "${YCSB_TEST3_MD5_RESTORED}" ]; then
    die "ycsb_test3 database md5 doesn't match: ${YCSB_TEST3_MD5_INITIAL} != ${YCSB_TEST3_MD5_RESTORED}"
  elif [ ${YCSB_TEST1_INITIAL_COUNT} -ne ${YCSB_TEST1_RESTORED_COUNT} ]; then
    die "ycsb_test1.usertable count: ${YCSB_TEST1_INITIAL_COUNT} != ${YCSB_TEST1_RESTORED_COUNT}"
  elif [ ${YCSB_TEST2_INITIAL_COUNT} -ne ${YCSB_TEST2_RESTORED_COUNT} ]; then
    die "ycsb_test2.usertable count: ${YCSB_TEST2_INITIAL_COUNT} != ${YCSB_TEST2_RESTORED_COUNT}"
  elif [ ${YCSB_TEST3_INITIAL_COUNT} -ne ${YCSB_TEST3_RESTORED_COUNT} ]; then
    die "ycsb_test3.usertable count: ${YCSB_TEST3_INITIAL_COUNT} != ${YCSB_TEST3_RESTORED_COUNT}"
  elif [ "${YCSB_TEST1_RESTORED_INDEX_COUNT}" != "3" ]; then
    die "ycsb_test1.usertable index count: ${YCSB_TEST1_RESTORED_INDEX_COUNT} != 3"
  elif [ "${YCSB_TEST2_RESTORED_INDEX_COUNT}" != "3" ]; then
    die "ycsb_test2.usertable index count: ${YCSB_TEST2_RESTORED_INDEX_COUNT} != 3"
  elif [ "${ADMIN_ROLE_RESTORED}" != "admin" ]; then
    die "admin role db issue: ${ADMIN_ROLE_RESTORED} != admin"
  elif [ "${ADMIN_USER_RESTORED}" != "myCustomAdminRole" ]; then
    die "admin user role issue: ${ADMIN_USER_RESTORED} != myCustomAdminRole"
  elif [ "${YCSB_TEST1_ROLE_RESTORED}" != "ycsb_test1" ]; then
    die "ycsb_test1 role db issue: ${YCSB_TEST1_ROLE_RESTORED} != ycsb_test1"
  elif [ "${YCSB_TEST1_USER_RESTORED}" != "myCustomRole1" ]; then
    die "ycsb_test1 user role issue: ${YCSB_TEST1_USER_RESTORED} != myCustomRole1"
  elif [ "${YCSB_TEST2_ROLE_RESTORED}" != "ycsb_test2" ]; then
    die "ycsb_test2 role db issue: ${YCSB_TEST2_ROLE_RESTORED} != ycsb_test2"
  elif [ "${YCSB_TEST2_USER_RESTORED}" != "myCustomRole2" ]; then
    die "ycsb_test2 user role issue: ${YCSB_TEST2_USER_RESTORED} != myCustomRole2"
  elif [ "${DATAGEN_MD5_INITIAL}" != "${DATAGEN_MD5_RESTORED}" ]; then
    die "datagen_it_test md5 issue: ${DATAGEN_MD5_INITIAL} != ${DATAGEN_MD5_RESTORED}"
  elif [ "${DATAGEN_TEST_BSON_RESTORED_COUNT}" != "200000" ]; then
    die "datagen_it_test test_bson count issue: ${DATAGEN_TEST_BSON_RESTORED_COUNT} != 200000"
  elif [ "${DATAGEN_TEST_AGG_RESTORED_COUNT}" != "1000" ]; then
    die "datagen_it_test test_agg count issue: ${DATAGEN_TEST_AGG_RESTORED_COUNT} != 1000"
  elif [ "${DATAGEN_TEST_AGG_DATA_RESTORED_COUNT}" != "10000" ]; then
    die "datagen_it_test test_agg_data count issue: ${DATAGEN_TEST_AGG_DATA_RESTORED_COUNT} != 10000"
  else
    vlog "All checks have passed."
  fi
}
