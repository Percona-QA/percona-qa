#!/usr/bin/env bash
# PBM: different tests for replica sets, sharding, local backup and minio backup
set -e

PQA_PATH=${HOME}/percona-qa
PBM_PATH=${HOME}/lab/pbm/pbm-latest
YCSB_PATH=${HOME}/lab/psmdb/ycsb-mongodb-binding-0.15.0
MONGODB_PATH=${HOME}/lab/psmdb/bin/percona-server-mongodb-4.0.10-5
TEST_RESULT_DIR="${MONGODB_PATH}/pbm-tests"
STORAGE_ENGINE="wiredTiger"
MONGODB_USER="dba"
MONGODB_PASS="test1234"
#
SAVE_STATE_BEFORE_RESTORE=0
PBM_COORD_API_TOKEN="abcdefgh"
PBM_COORD_ADDRESS="127.0.0.1:10001"
# don't change
SCRIPT_PWD=$(cd `dirname $0` && pwd)
RUN_TEST="${1:-all}"
TEST_RESULT=0
PBMCTL_OPTS="--api-token=${PBM_COORD_API_TOKEN} --server-address=${PBM_COORD_ADDRESS}"

cd ${MONGODB_PATH}

prepare_environment() {
  mkdir -p ${TEST_RESULT_DIR}
  if [ ! -d ${TEST_RESULT_DIR}/tools ]; then
    mkdir -p ${TEST_RESULT_DIR}/tools
    pushd ${TEST_RESULT_DIR}/tools
    rm -f mgodatagen_linux_x86_64.tar.gz
    wget --no-verbose https://github.com/feliixx/mgodatagen/releases/download/0.7.4/mgodatagen_linux_x86_64.tar.gz > /dev/null 2>&1
    tar xf mgodatagen_linux_x86_64.tar.gz
    rm -f mgodatagen_linux_x86_64.tar.gz
    cp ${SCRIPT_PWD}/mgodatagen.json ${TEST_RESULT_DIR}/tools
    popd
  fi
}

start_replica() {
  echo "##### ${TEST_NAME}: Starting replica set rs1 #####"
  ${PQA_PATH}/mongo_startup.sh --rSet --pbmDir=${PBM_PATH} --storageEngine=${STORAGE_ENGINE} --auth
}

start_sharding_cluster() {
  echo "##### ${TEST_NAME}: Starting sharding cluster #####"
  ${PQA_PATH}/mongo_startup.sh --sCluster --pbmDir=${PBM_PATH} --storageEngine=${STORAGE_ENGINE} --auth
}

stop_all_mongo() {
  echo "##### ${TEST_NAME}: Stopping all mongodb processes #####"
  ${MONGODB_PATH}/nodes/stop_mongodb.sh
}

stop_all_pbm() {
  echo "##### ${TEST_NAME}: Stopping all PBM processes #####"
  ${MONGODB_PATH}/nodes/stop_pbm.sh
}

ycsb_load() {
  local MONGODB_URL="$1"
  local YCSB_RECORD_COUNT="$2"
  local YCSB_OPERATIONS_COUNT="$3"
  local YCSB_THREADS="$4"

  pushd ${YCSB_PATH}
  echo "##### ${TEST_NAME}: Starting YCSB insert load #####"
  ${YCSB_PATH}/bin/ycsb load mongodb -s -P workloads/workloadb -p recordcount=${YCSB_RECORD_COUNT} -p operationcount=${YCSB_OPERATIONS_COUNT} -threads ${YCSB_THREADS} -p mongodb.url="${MONGODB_URL}" -p mongodb.auth="true"
  popd
}

ycsb_run() {
  local MONGODB_URL="$1"
  local YCSB_RECORD_COUNT="$2"
  local YCSB_OPERATIONS_COUNT="$3"
  local YCSB_THREADS="$4"

  pushd ${YCSB_PATH}
  echo "##### ${TEST_NAME}: Starting YCSB oltp run #####"
  ${YCSB_PATH}/bin/ycsb run mongodb -s -P workloads/workloadb -p recordcount=${YCSB_RECORD_COUNT} -p operationcount=${YCSB_OPERATIONS_COUNT} -threads ${YCSB_THREADS} -p mongodb.url="${MONGODB_URL}" -p mongodb.auth="true"
  popd
}

get_backup_id() {
  local BACKUP_DESC="$1"
  ${MONGODB_PATH}/nodes/pbmctl list backups ${PBMCTL_OPTS} 2>&1|grep "${BACKUP_DESC}" |grep -oE "^.*\.json"
}

get_replica_primary() {
  local HOST=$1
  local PORT=$2
  ${MONGODB_PATH}/bin/mongo --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --eval 'rs.isMaster().primary' --host=${HOST} --port=${PORT} --quiet|tail -n1
}

log_status() {
  local LOG_FILE="$1"
  local CLUSTER_TYPE="$2"
  local PRIMARY=""
  echo "##### DATABASES LIST #####" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand( { listDatabases: 1 } )' --quiet >> ${LOG_FILE}
  echo "##### ADMIN DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "##### YCSB_TEST1 DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "db.usertable.count()" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "##### YCSB_TEST2 DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "db.usertable.count()" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "##### YCSB_TEST3 DATABASE USER AND ROLES COUNT #####" >> ${LOG_FILE}
  echo "USERS" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  echo "ROLES" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  echo "db.usertable.count()" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "##### DATAGEN_IT_TEST DATABASE COLLECTION COUNTS #####" >> ${LOG_FILE}
  echo "db.test_bson.count()" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_bson.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "db.test_agg.count()" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg.count()' --quiet | tail -n1 >> ${LOG_FILE}
  echo "db.test_agg_data.count()" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg_data.count()' --quiet | tail -n1 >> ${LOG_FILE}
  if [ "${CLUSTER_TYPE}" == "sharding" ]; then
    PRIMARY=$(get_replica_primary localhost 27018)
    echo "##### YCSB_TEST1 DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST2 DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST3 DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### DATAGEN_IT_TEST DATABASE MD5 ON RS1 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    PRIMARY=$(get_replica_primary localhost 28018)
    echo "##### YCSB_TEST1 DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST2 DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST3 DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### DATAGEN_IT_TEST DATABASE MD5 ON RS2 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet >> ${LOG_FILE}
    echo "##### SHARDING STATUS #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.status()' --quiet >> ${LOG_FILE}
  else
    echo "##### YCSB_TEST1 DATABASE MD5 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST2 DATABASE MD5 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
    echo "##### YCSB_TEST3 DATABASE MD5 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
    echo "##### DATAGEN_IT_TEST DATABASE MD5 #####" >> ${LOG_FILE}
    ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
  fi
}

check_cleanup() {
  if [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUser("tomislav_admin")' --quiet|tail -n1)" != "null" ]; then
    echo "Cleanup not completed fully! admin contains tomislav_admin user."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRole("myCustomAdminRole")' --quiet|tail -n1)" != "null" ]; then
    echo "Cleanup not completed fully! admin contains myCustomAdminRole."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test1 contains collections."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUsers().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test1 contains users."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRoles().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test1 contains roles."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test2 contains collections."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUsers().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test2 contains users."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRoles().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test2 contains roles."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! ycsb_test3 contains collections."
    TEST_RESULT=1
  elif [ "$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.getCollectionInfos().length' --quiet|tail -n1)" != "0" ]; then
    echo "Cleanup not completed fully! datagen_it_test contains collections."
    TEST_RESULT=1
  fi
}

cleanup() {
  echo "##### ${TEST_NAME}: Data cleanup #####"
  stop_all_pbm
  stop_all_mongo
  sleep 5
  rm -rf ${MONGODB_PATH}/pbm-test-temp
  mv ${MONGODB_PATH}/nodes ${MONGODB_PATH}/pbm-test-temp
  #mkdir ${MONGODB_PATH}/pbm-test-temp
  #mv ${MONGODB_PATH}/nodes/backup ${MONGODB_PATH}/pbm-test-temp
  #mv ${MONGODB_PATH}/nodes/pbm-coordinator/workdir ${MONGODB_PATH}/pbm-test-temp
  #rm -rf ${MONGODB_PATH}/nodes
  if [ "$1" == "sharding" ]; then
    start_sharding_cluster
  else
    start_replica
  fi
  sleep 10
  mv ${MONGODB_PATH}/pbm-test-temp/backup ${MONGODB_PATH}/nodes
  mv ${MONGODB_PATH}/pbm-test-temp/pbm-coordinator/workdir ${MONGODB_PATH}/nodes/pbm-coordinator
  if [ ${SAVE_STATE_BEFORE_RESTORE} -eq 0 ]; then
    rm -rf ${MONGODB_PATH}/pbm-test-temp
  fi
  ## drop users (dropping a database doesn't drop users/roles!!!)
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.dropUser("tomislav_admin", {w: "majority", wtimeout: 5000})' --quiet
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.dropUser("tomislav", {w: "majority", wtimeout: 5000})' --quiet
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.dropUser("ivana", {w: "majority", wtimeout: 5000})' --quiet
  ## drop roles (dropping a database doesn't drop users/roles!!!)
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.dropRole( "myCustomAdminRole", { w: "majority" } )' --quiet
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.dropRole( "myCustomRole1", { w: "majority" } )' --quiet
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.dropRole( "myCustomRole2", { w: "majority" } )' --quiet
  ## finally drop database
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.dropDatabase()' --quiet
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.dropDatabase()' --quiet
  #${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.dropDatabase()' --quiet
}

prepare_data() {
  echo "##### ${TEST_NAME}: Preparing data #####"
  # create databases/collections
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.createCollection("usertable")' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.createCollection("usertable")' --quiet
  if [ "$1" == "sharding" ]; then
    ${TEST_RESULT_DIR}/tools/mgodatagen --file=${TEST_RESULT_DIR}/tools/mgodatagen.json --host=localhost --port=27017 --username=${MONGODB_USER} --password=${MONGODB_PASS}
  else
    PRIMARY=$(get_replica_primary localhost 27017 | cut -d':' -f2)
    ${TEST_RESULT_DIR}/tools/mgodatagen --file=${TEST_RESULT_DIR}/tools/mgodatagen.json --host=localhost --port=${PRIMARY} --username=${MONGODB_USER} --password=${MONGODB_PASS}
  fi
  # create roles
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.createRole({ role: "myCustomAdminRole", privileges: [{ resource: { db: "ycsb_test1", collection: "" }, actions: [ "find", "update", "insert", "remove" ] }], roles: [{ role: "root", db: "admin" }]}, { w: "majority" , wtimeout: 5000 })' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.createRole({ role: "myCustomRole1", privileges: [{ resource: { db: "ycsb_test1", collection: "" }, actions: [ "find", "update", "insert", "remove" ] }], roles: [ ]}, { w: "majority" , wtimeout: 5000 })' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.createRole({ role: "myCustomRole2", privileges: [{ resource: { db: "ycsb_test2", collection: "" }, actions: [ "find", "update", "insert", "remove" ] }], roles: [ ]}, { w: "majority" , wtimeout: 5000 })' --quiet
  # create users
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.createUser({user: "tomislav_admin", pwd: "test12345", roles: [ "myCustomAdminRole" ] });' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.createUser({user: "tomislav", pwd: "test12345", roles: [ "myCustomRole1" ] });' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.createUser({user: "ivana", pwd: "test12345", roles: [ "myCustomRole2" ] });' --quiet
  # add indexes
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field1: 1, field2: -1 })' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field3: -1, field4: 1 })' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field1: 1, field2: -1 })' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.createIndex({ field3: -1, field4: 1 })' --quiet
  # insert data
  ycsb_load "${MONGODB_URI}ycsb_test1${MONGODB_OPTS}" 10000 10000 8
  ycsb_load "${MONGODB_URI}ycsb_test2${MONGODB_OPTS}" 500000 500000 8
  sleep 10
}

get_hashes_counts_before() {
  echo "##### ${TEST_NAME}: Get DB hashes and document counts before restore #####"
  # for sharding dbHash doesn't work on mongos and we need to get hashes from all shards
  if [ "$1" == "sharding" ]; then
    local PRIMARY=""
    PRIMARY=$(get_replica_primary localhost 27018)
    local RS1_YCSB_TEST1_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS1_YCSB_TEST2_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS1_YCSB_TEST3_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    ${MONGODB_PATH}/bin/mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:27018,localhost:27019,localhost:27020/ycsb_test3?replicaSet=rs1&authSource=admin" --collection usertable --type csv --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs1-oplog-export-before.csv
    local RS1_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs1-oplog-export-before.csv|cut -d' ' -f1)
    local RS1_DATAGEN_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    PRIMARY=$(get_replica_primary localhost 28018)
    local RS2_YCSB_TEST1_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS2_YCSB_TEST2_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS2_YCSB_TEST3_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    ${MONGODB_PATH}/bin/mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:28018,localhost:28019,localhost:28020/ycsb_test3?replicaSet=rs2&authSource=admin" --collection usertable --type csv --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs2-oplog-export-before.csv
    local RS2_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs2-oplog-export-before.csv|cut -d' ' -f1)
    local RS2_DATAGEN_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    YCSB_TEST1_MD5_INITIAL="${RS1_YCSB_TEST1_TEMP}+${RS2_YCSB_TEST1_TEMP}"
    YCSB_TEST2_MD5_INITIAL="${RS1_YCSB_TEST2_TEMP}+${RS2_YCSB_TEST2_TEMP}"
    YCSB_TEST3_MD5_INITIAL="${RS1_YCSB_TEST3_TEMP}+${RS2_YCSB_TEST3_TEMP}"
    DATAGEN_MD5_INITIAL="${RS1_DATAGEN_TEMP}+${RS2_DATAGEN_TEMP}"
  else
    YCSB_TEST1_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    YCSB_TEST2_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    #YCSB_TEST3_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    ${MONGODB_PATH}/bin/mongoexport --uri=${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --collection usertable --type csv --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-oplog-export-before.csv
    YCSB_TEST3_MD5_INITIAL=$(md5sum -b ${TEST_DIR}/ycsb_test3-oplog-export-before.csv|cut -d' ' -f1)
    DATAGEN_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  fi
  YCSB_TEST1_INITIAL_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST2_INITIAL_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST3_INITIAL_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
}

get_hashes_counts_after() {
  echo "##### ${TEST_NAME}: Get DB hashes and document counts after restore #####"
  # for sharding dbHash doesn't work on mongos and we need to get hashes from all shards
  if [ "$1" == "sharding" ]; then
    local PRIMARY=""
    PRIMARY=$(get_replica_primary localhost 27018)
    local RS1_YCSB_TEST1_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS1_YCSB_TEST2_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS1_YCSB_TEST3_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    ${MONGODB_PATH}/bin/mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:27018,localhost:27019,localhost:27020/ycsb_test3?replicaSet=rs1&authSource=admin" --collection usertable --type csv --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs1-oplog-export-after.csv
    local RS1_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs1-oplog-export-after.csv|cut -d' ' -f1)
    local RS1_DATAGEN_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    PRIMARY=$(get_replica_primary localhost 28018)
    local RS2_YCSB_TEST1_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test1 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    local RS2_YCSB_TEST2_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test2 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #local RS2_YCSB_TEST3_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/ycsb_test3 --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    ${MONGODB_PATH}/bin/mongoexport --uri="mongodb://${MONGODB_USER}:${MONGODB_PASS}@localhost:28018,localhost:28019,localhost:28020/ycsb_test3?replicaSet=rs2&authSource=admin" --collection usertable --type csv --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-rs2-oplog-export-after.csv
    local RS2_YCSB_TEST3_TEMP==$(md5sum -b ${TEST_DIR}/ycsb_test3-rs2-oplog-export-after.csv|cut -d' ' -f1)
    local RS2_DATAGEN_TEMP=$(${MONGODB_PATH}/bin/mongo ${PRIMARY}/datagen_it_test --eval 'db.runCommand({ dbHash: 1 }).md5' --username=${MONGODB_USER} --password=${MONGODB_PASS} --authenticationDatabase=admin --quiet|tail -n1)
    #
    YCSB_TEST1_MD5_RESTORED="${RS1_YCSB_TEST1_TEMP}+${RS2_YCSB_TEST1_TEMP}"
    YCSB_TEST2_MD5_RESTORED="${RS1_YCSB_TEST2_TEMP}+${RS2_YCSB_TEST2_TEMP}"
    YCSB_TEST3_MD5_RESTORED="${RS1_YCSB_TEST3_TEMP}+${RS2_YCSB_TEST3_TEMP}"
    DATAGEN_MD5_RESTORED="${RS1_DATAGEN_TEMP}+${RS2_DATAGEN_TEMP}"
  else
    YCSB_TEST1_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    YCSB_TEST2_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    #YCSB_TEST3_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
    ${MONGODB_PATH}/bin/mongoexport --uri=${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --collection usertable --type csv --fields _id,field0,field1,field2,field3,field4,field5,field6,field7,field8,field9 --noHeaderLine --out ${TEST_DIR}/ycsb_test3-oplog-export-after.csv
    YCSB_TEST3_MD5_RESTORED=$(md5sum -b ${TEST_DIR}/ycsb_test3-oplog-export-after.csv|cut -d' ' -f1)
    DATAGEN_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  fi
  YCSB_TEST1_RESTORED_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST2_RESTORED_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST3_RESTORED_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST1_RESTORED_INDEX_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.getIndexes().length' --quiet|tail -n1)
  YCSB_TEST2_RESTORED_INDEX_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.getIndexes().length' --quiet|tail -n1)
  ADMIN_ROLE_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRole("myCustomAdminRole").db' --quiet|tail -n1)
  ADMIN_USER_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUser("tomislav_admin").roles[0].role' --quiet|tail -n1)
  YCSB_TEST1_ROLE_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRole("myCustomRole1").db' --quiet|tail -n1)
  YCSB_TEST1_USER_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUser("tomislav").roles[0].role' --quiet|tail -n1)
  YCSB_TEST2_ROLE_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRole("myCustomRole2").db' --quiet|tail -n1)
  YCSB_TEST2_USER_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUser("ivana").roles[0].role' --quiet|tail -n1)
  DATAGEN_TEST_BSON_RESTORED_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_bson.count()' --quiet|tail -n1)
  DATAGEN_TEST_AGG_RESTORED_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg.count()' --quiet|tail -n1)
  DATAGEN_TEST_AGG_DATA_RESTORED_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}datagen_it_test${MONGODB_OPTS} --eval 'db.test_agg_data.count()' --quiet|tail -n1)
}

check_after_restore() {
  echo "##### ${TEST_NAME}: Doing checks after restore #####"
  if [ "${YCSB_TEST1_MD5_INITIAL}" != "${YCSB_TEST1_MD5_RESTORED}" ]; then
    echo "ycsb_test1 database md5 doesn't match: ${YCSB_TEST1_MD5_INITIAL} != ${YCSB_TEST1_MD5_RESTORED}"
    TEST_RESULT=1
  elif [ "${YCSB_TEST2_MD5_INITIAL}" != "${YCSB_TEST2_MD5_RESTORED}" ]; then
    echo "ycsb_test2 database md5 doesn't match: ${YCSB_TEST2_MD5_INITIAL} != ${YCSB_TEST2_MD5_RESTORED}"
    TEST_RESULT=1
  elif [ "${YCSB_TEST3_MD5_INITIAL}" != "${YCSB_TEST3_MD5_RESTORED}" ]; then
    echo "ycsb_test3 database md5 doesn't match: ${YCSB_TEST3_MD5_INITIAL} != ${YCSB_TEST3_MD5_RESTORED}"
    TEST_RESULT=1
  elif [ ${YCSB_TEST1_INITIAL_COUNT} -ne ${YCSB_TEST1_RESTORED_COUNT} ]; then
    echo "ycsb_test1.usertable count: ${YCSB_TEST1_INITIAL_COUNT} != ${YCSB_TEST1_RESTORED_COUNT}"
    TEST_RESULT=1
  elif [ ${YCSB_TEST2_INITIAL_COUNT} -ne ${YCSB_TEST2_RESTORED_COUNT} ]; then
    echo "ycsb_test2.usertable count: ${YCSB_TEST2_INITIAL_COUNT} != ${YCSB_TEST2_RESTORED_COUNT}"
    TEST_RESULT=1
  elif [ ${YCSB_TEST3_INITIAL_COUNT} -ne ${YCSB_TEST3_RESTORED_COUNT} ]; then
    echo "ycsb_test3.usertable count: ${YCSB_TEST3_INITIAL_COUNT} != ${YCSB_TEST3_RESTORED_COUNT}"
    TEST_RESULT=1
  elif [ "${YCSB_TEST1_RESTORED_INDEX_COUNT}" != "3" ]; then
    echo "ycsb_test1.usertable index count: ${YCSB_TEST1_RESTORED_INDEX_COUNT} != 3"
    TEST_RESULT=1
  elif [ "${YCSB_TEST2_RESTORED_INDEX_COUNT}" != "3" ]; then
    echo "ycsb_test2.usertable index count: ${YCSB_TEST2_RESTORED_INDEX_COUNT} != 3"
    TEST_RESULT=1
  elif [ "${ADMIN_ROLE_RESTORED}" != "admin" ]; then
    echo "admin role db issue: ${ADMIN_ROLE_RESTORED} != admin"
    TEST_RESULT=1
  elif [ "${ADMIN_USER_RESTORED}" != "myCustomAdminRole" ]; then
    echo "admin user role issue: ${ADMIN_USER_RESTORED} != myCustomAdminRole"
    TEST_RESULT=1
  elif [ "${YCSB_TEST1_ROLE_RESTORED}" != "ycsb_test1" ]; then
    echo "ycsb_test1 role db issue: ${YCSB_TEST1_ROLE_RESTORED} != ycsb_test1"
    TEST_RESULT=1
  elif [ "${YCSB_TEST1_USER_RESTORED}" != "myCustomRole1" ]; then
    echo "ycsb_test1 user role issue: ${YCSB_TEST1_USER_RESTORED} != myCustomRole1"
    TEST_RESULT=1
  elif [ "${YCSB_TEST2_ROLE_RESTORED}" != "ycsb_test2" ]; then
    echo "ycsb_test2 role db issue: ${YCSB_TEST2_ROLE_RESTORED} != ycsb_test2"
    TEST_RESULT=1
  elif [ "${YCSB_TEST2_USER_RESTORED}" != "myCustomRole2" ]; then
    echo "ycsb_test2 user role issue: ${YCSB_TEST2_USER_RESTORED} != myCustomRole2"
    TEST_RESULT=1
  elif [ "${DATAGEN_MD5_INITIAL}" != "${DATAGEN_MD5_RESTORED}" ]; then
    echo "datagen_it_test md5 issue: ${DATAGEN_MD5_INITIAL} != ${DATAGEN_MD5_RESTORED}"
    TEST_RESULT=1
  elif [ "${DATAGEN_TEST_BSON_RESTORED_COUNT}" != "200000" ]; then
    echo "datagen_it_test test_bson count issue: ${DATAGEN_TEST_BSON_RESTORED_COUNT} != 200000"
    TEST_RESULT=1
  elif [ "${DATAGEN_TEST_AGG_RESTORED_COUNT}" != "1000" ]; then
    echo "datagen_it_test test_agg count issue: ${DATAGEN_TEST_AGG_RESTORED_COUNT} != 1000"
    TEST_RESULT=1
  elif [ "${DATAGEN_TEST_AGG_DATA_RESTORED_COUNT}" != "10000" ]; then
    echo "datagen_it_test test_agg_data count issue: ${DATAGEN_TEST_AGG_DATA_RESTORED_COUNT} != 10000"
    TEST_RESULT=1
  else
    echo "All checks have passed."
  fi
}

test_replica() {
  local TEST_STORAGE="$1"

  TEST_NAME="test-replica-${TEST_STORAGE}"
  TEST_DIR="${TEST_RESULT_DIR}/${TEST_NAME}"
  rm -rf ${TEST_DIR} && mkdir -p ${TEST_DIR}
  MONGODB_NODES="localhost:27017,localhost:27018,localhost:27019"
  MONGODB_URI="mongodb://${MONGODB_USER}:${MONGODB_PASS}@${MONGODB_NODES}/"
  MONGODB_OPTS="?replicaSet=rs1&authSource=admin"

  echo "##### ${TEST_NAME}: Starting test #####"
  start_replica
  prepare_data replica
  # run some load in background so that oplog also gets into backup
  ycsb_load "${MONGODB_URI}ycsb_test3${MONGODB_OPTS}" 100000 100000 4 >/dev/null 2>&1 &
  # below is alternative good for debuging
  # ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'for(i=1; i <= 40000; i++) { db.usertable.insert({ _id: i, field1: "a", field0: "b", field7: "c" })}' --quiet >/dev/null 2>&1 &
  sleep 5
  # create backup to local filesystem
  echo "##### ${TEST_NAME}: Doing backup #####"
  ${MONGODB_PATH}/nodes/pbmctl run backup --description="${TEST_NAME}" --storage=${TEST_STORAGE} ${PBMCTL_OPTS}
  BACKUP_ID=$(get_backup_id ${TEST_NAME})
  echo "##### ${TEST_NAME}: Backup: ${BACKUP_ID} completed #####"
  # create db hash and get document counts
  get_hashes_counts_before replica
  echo "##### ${TEST_NAME}: Log status before restore #####"
  log_status ${TEST_DIR}/rs1_before_restore.log replica
  # drop roles / users / databases
  cleanup replica
  check_cleanup
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "${TEST_NAME}: Stopping because cleanup was not done fully during test. ${TEST_NAME}"
    exit 1
  fi
  echo "##### ${TEST_NAME}: Log status after cleanup #####"
  log_status ${TEST_DIR}/rs1_after_cleanup.log replica
  # do restore from local filesystem
  echo "##### ${TEST_NAME}: Doing restore of: ${BACKUP_ID} #####"
  ${MONGODB_PATH}/nodes/pbmctl run restore --storage=${TEST_STORAGE} ${PBMCTL_OPTS} ${BACKUP_ID}
  echo "##### ${TEST_NAME}: Restore from: ${BACKUP_ID} completed #####"
  echo "##### ${TEST_NAME}: Log status after restore #####"
  log_status ${TEST_DIR}/rs1_after_restore.log replica
  # create db hash and get document counts
  get_hashes_counts_after replica
  check_after_restore
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "${TEST_NAME}: Stopping because check after restore is not ok. ${TEST_NAME}"
    exit 1
  fi
  stop_all_pbm
  stop_all_mongo
  sleep 5
  mv ${MONGODB_PATH}/nodes ${TEST_DIR}
  echo "##### ${TEST_NAME}: Finished OK #####"
}

test_sharding() {
  local TEST_STORAGE="$1"

  TEST_NAME="test-sharding-${TEST_STORAGE}"
  TEST_DIR="${TEST_RESULT_DIR}/${TEST_NAME}"
  rm -rf ${TEST_DIR} && mkdir -p ${TEST_DIR}
  MONGODB_NODES="localhost:27017"
  MONGODB_URI="mongodb://${MONGODB_USER}:${MONGODB_PASS}@${MONGODB_NODES}/"
  MONGODB_OPTS="?authSource=admin"

  echo "##### ${TEST_NAME}: Starting test #####"
  start_sharding_cluster
  prepare_data sharding
  echo "##### ${TEST_NAME}: Enabling sharding collections for ycsb_test1 and ycsb_test2 #####"
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.enableSharding("ycsb_test1");' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.enableSharding("ycsb_test2");' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.shardCollection("ycsb_test1.usertable", { _id : 1 } );' --quiet
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.shardCollection("ycsb_test2.usertable", { _id : 1 } );' --quiet
  sleep 7
  # run some load in background so that oplog also gets into backup
  ycsb_load "${MONGODB_URI}ycsb_test3${MONGODB_OPTS}" 100000 100000 4 >/dev/null 2>&1 &
  # below is alternative good for debuging
  # ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'for(i=1; i <= 40000; i++) { db.usertable.insert({ _id: i, field1: "a", field0: "b", field7: "c" })}' --quiet >/dev/null 2>&1 &
  sleep 5
  # create backup
  echo "##### ${TEST_NAME}: Doing backup #####"
  ${MONGODB_PATH}/nodes/pbmctl run backup --description="${TEST_NAME}" --storage=${TEST_STORAGE} ${PBMCTL_OPTS}
  echo "##### ${TEST_NAME}: Backup: ${BACKUP_ID} completed #####"
  # stop the balancer so it doesn't change data on the shards before we record dbhash
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand({ balancerStop: 1 });' --quiet
  BACKUP_ID=$(get_backup_id ${TEST_NAME})
  # create db hash and get document counts
  get_hashes_counts_before sharding
  echo "##### ${TEST_NAME}: Log status before restore #####"
  log_status ${TEST_DIR}/sh1_before_restore.log sharding
  # drop roles / users / databases
  cleanup sharding
  check_cleanup
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "${TEST_NAME}: Stopping because cleanup was not done fully during test. ${TEST_NAME}"
    exit 1
  fi
  echo "##### ${TEST_NAME}: Log status after cleanup #####"
  log_status ${TEST_DIR}/sh1_after_cleanup.log sharding
  # do restore from selected storage
  echo "##### ${TEST_NAME}: Doing restore of: ${BACKUP_ID} #####"
  # stop the balancer so it doesn't change data on the shards before we record dbhash
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand({ balancerStop: 1 });' --quiet
  ${MONGODB_PATH}/nodes/pbmctl run restore --storage=${TEST_STORAGE} ${PBMCTL_OPTS} ${BACKUP_ID}
  echo "##### ${TEST_NAME}: Restore from: ${BACKUP_ID} completed #####"
  echo "##### ${TEST_NAME}: Log status after restore #####"
  log_status ${TEST_DIR}/sh1_after_restore.log sharding
  # create db hash and get document counts
  get_hashes_counts_after sharding
  check_after_restore
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "${TEST_NAME}: Stopping because check after restore is not ok. ${TEST_NAME}"
    exit 1
  fi
  stop_all_pbm
  stop_all_mongo
  sleep 5
  mv ${MONGODB_PATH}/nodes ${TEST_DIR}
  echo "##### ${TEST_NAME}: Finished OK #####"
}

###
### PREPARE ENVIRONMENT
###
prepare_environment

###
### RUN TESTS
###
if [ "${RUN_TEST}" = "test-replica-local" -o "${RUN_TEST}" = "all" ]; then
  test_replica local-filesystem
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "Stopping because of failed test: ${TEST_NAME}"
    exit 1
  fi
fi
if [ "${RUN_TEST}" = "test-replica-minio" -o "${RUN_TEST}" = "all" ]; then
  test_replica minio-s3
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "Stopping because of failed test: ${TEST_NAME}"
    exit 1
  fi
fi
if [ "${RUN_TEST}" = "test-sharding-local" -o "${RUN_TEST}" = "all" ]; then
  test_sharding local-filesystem
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "Stopping because of failed test: ${TEST_NAME}"
    exit 1
  fi
fi
if [ "${RUN_TEST}" = "test-sharding-minio" -o "${RUN_TEST}" = "all" ]; then
  test_sharding minio-s3
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "Stopping because of failed test: ${TEST_NAME}"
    exit 1
  fi
fi

echo "##### All tests finished successfully! #####"
