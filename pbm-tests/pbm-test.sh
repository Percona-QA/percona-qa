#!/usr/bin/env bash
# PBM: different tests for replica sets, sharding, local backup and minio backup
set -e

PQA_PATH=/home/plavi/percona-qa
PBM_PATH=/home/plavi/lab/pbm/pbm-latest
YCSB_PATH=/home/plavi/lab/psmdb/ycsb-mongodb-binding-0.15.0
MONGODB_PATH=/home/plavi/lab/psmdb/bin/percona-server-mongodb-3.6.12-3.2
STORAGE_ENGINE="wiredTiger"
MONGODB_USER="dba"
MONGODB_PASS="test1234"
#
TEST_RESULT=0

cd ${MONGODB_PATH}
mkdir pbm-tests

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
  if [ -x ${MONGODB_PATH}/nodes/stop_all.sh ]; then
    ${MONGODB_PATH}/nodes/stop_all.sh
  else
    ${MONGODB_PATH}/nodes/stop_rs.sh
  fi
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
  ${MONGODB_PATH}/nodes/pbmctl list backups 2>&1|grep "${BACKUP_DESC}" |grep -oE "^.*\.json"
}

log_rs_status() {
  local LOG_FILE="$1"
  echo "##### DATABASES LIST #####" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand( { listDatabases: 1 } )' --quiet >> ${LOG_FILE}
  echo "##### ADMIN DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
  echo "##### YCSB_TEST1 DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet >> ${LOG_FILE}
  echo "##### YCSB_TEST2 DATABASE USERS AND ROLES #####" >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getUsers()' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.getRoles()' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 })' --quiet >> ${LOG_FILE}
  ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet >> ${LOG_FILE}
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
  fi
}

cleanup() {
  echo "##### ${TEST_NAME}: Data cleanup #####"
  stop_all_pbm
  stop_all_mongo
  sleep 5
  mkdir ${MONGODB_PATH}/pbm-test-temp
  mv ${MONGODB_PATH}/nodes/backup ${MONGODB_PATH}/pbm-test-temp
  mv ${MONGODB_PATH}/nodes/pbm-coordinator/workdir ${MONGODB_PATH}/pbm-test-temp
  rm -rf ${MONGODB_PATH}/nodes
  start_replica
  sleep 10
  mv ${MONGODB_PATH}/pbm-test-temp/backup ${MONGODB_PATH}/nodes
  mv ${MONGODB_PATH}/pbm-test-temp/workdir ${MONGODB_PATH}/nodes/pbm-coordinator
  rm -rf ${MONGODB_PATH}/pbm-test-temp
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
  sleep 5
}

get_hashes_counts_before() {
  echo "##### ${TEST_NAME}: Get DB hashes and document counts before backup #####"
  YCSB_TEST1_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  YCSB_TEST2_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  YCSB_TEST3_MD5_INITIAL=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  YCSB_TEST1_INITIAL_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST2_INITIAL_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
  YCSB_TEST3_INITIAL_COUNT=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.usertable.count()' --quiet|tail -n1)
}

get_hashes_counts_after() {
  echo "##### ${TEST_NAME}: Get DB hashes and document counts after restore #####"
  YCSB_TEST1_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test1${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  YCSB_TEST2_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test2${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
  YCSB_TEST3_MD5_RESTORED=$(${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'db.runCommand({ dbHash: 1 }).md5' --quiet|tail -n1)
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
  else
    echo "All checks have passed."
  fi
}

test_replica() {
  local TEST_STORAGE="$1"

  TEST_NAME="test-replica-${TEST_STORAGE}"
  TEST_DIR="${MONGODB_PATH}/pbm-tests/${TEST_NAME}"
  rm -rf ${TEST_DIR} && mkdir -p ${TEST_DIR}
  MONGODB_NODES="localhost:27017,localhost:27018,localhost:27019"
  MONGODB_URI="mongodb://${MONGODB_USER}:${MONGODB_PASS}@${MONGODB_NODES}/"
  MONGODB_OPTS="?replicaSet=rs1&authSource=admin"

  echo "##### ${TEST_NAME}: Starting test #####"
  start_replica
  prepare_data
  # run some load in background so that oplog also gets into backup
  ycsb_load "${MONGODB_URI}ycsb_test3${MONGODB_OPTS}" 200000 200000 8 >/dev/null 2>&1 &
  sleep 5
  # create backup to local filesystem
  echo "##### ${TEST_NAME}: Doing backup #####"
  ${MONGODB_PATH}/nodes/pbmctl run backup --description="${TEST_NAME}" --storage=${TEST_STORAGE}
  BACKUP_ID=$(get_backup_id ${TEST_NAME})
  echo "##### ${TEST_NAME}: Backup: ${BACKUP_ID} completed #####"
  # create db hash and get document counts
  get_hashes_counts_before
  echo "##### ${TEST_NAME}: Log status before restore #####"
  log_rs_status ${TEST_DIR}/rs1_before_restore.log
  # create db hash and get document counts
  get_hashes_counts_after
  # drop roles / users / databases
  cleanup
  check_cleanup
  if [ ${TEST_RESULT} -ne 0 ]; then
    echo "${TEST_NAME}: Stopping because cleanup was not done fully during test. ${TEST_NAME}"
    exit 1
  fi
  echo "##### ${TEST_NAME}: Log status after cleanup #####"
  log_rs_status ${TEST_DIR}/rs1_after_cleanup.log
  # do restore from local filesystem
  echo "##### ${TEST_NAME}: Doing restore of: ${BACKUP_ID} #####"
  ${MONGODB_PATH}/nodes/pbmctl run restore --storage=${TEST_STORAGE} ${BACKUP_ID}
  echo "##### ${TEST_NAME}: Restore from: ${BACKUP_ID} completed #####"
  echo "##### ${TEST_NAME}: Log status after restore #####"
  log_rs_status ${TEST_DIR}/rs1_after_restore.log
  check_after_restore
  stop_all_pbm
  stop_all_mongo
  sleep 5
  mv ${MONGODB_PATH}/nodes ${TEST_DIR}
  echo "##### ${TEST_NAME}: Finished OK #####"
}

###
### RUN TESTS
###
test_replica local-filesystem
if [ ${TEST_RESULT} -ne 0 ]; then
  echo "Stopping because of failed test: ${TEST_NAME}"
  exit 1
fi
test_replica s3-us-west
if [ ${TEST_RESULT} -ne 0 ]; then
  echo "Stopping because of failed test: ${TEST_NAME}"
  exit 1
fi
# TODO: SHARDING CLUSTER TEST

echo "##### All tests finished successfully! #####"
