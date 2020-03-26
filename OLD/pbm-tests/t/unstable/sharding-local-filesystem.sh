# general sharding test (long one)
. ${PQA_PATH}/pbm-tests/inc/common.sh

TEST_STORAGE="local-filesystem"
TEST_NAME="test-sharding-${TEST_STORAGE}"
TEST_DIR="${TEST_RESULT_DIR}/results/${TEST_NAME}"
rm -rf ${TEST_DIR} && mkdir -p ${TEST_DIR}
EXTRA_STARTUP_OPTS=""
MONGODB_NODES="${HOST}:27017"
MONGODB_URI="mongodb://${MONGODB_USER}:${MONGODB_PASS}@${MONGODB_NODES}/"
MONGODB_OPTS="?authSource=admin"

start_sharding_cluster
prepare_data sharding
vlog "Enabling sharding collections for ycsb_test1 and ycsb_test2"
run_cmd mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.enableSharding("ycsb_test1");' --quiet
run_cmd mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.enableSharding("ycsb_test2");' --quiet
run_cmd mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.shardCollection("ycsb_test1.usertable", { _id : 1 } );' --quiet
run_cmd mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'sh.shardCollection("ycsb_test2.usertable", { _id : 1 } );' --quiet
sleep 7
# run some load in background so that oplog also gets into backup
run_cmd ycsb load mongodb -s -P ${YCSB_PATH}/workloads/workloadb -p recordcount=100000 -p operationcount=100000 -threads 4 -p mongodb.url="${MONGODB_URI}ycsb_test3${MONGODB_OPTS}" -p mongodb.auth="true" >/dev/null 2>&1 &
sleep 5
# create backup
vlog "Doing backup"
run_cmd pbmctl run backup --description="${TEST_NAME}" --storage=${TEST_STORAGE} ${PBMCTL_OPTS}
# stop the balancer so it doesn't change data on the shards before we record dbhash
run_cmd mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand({ balancerStop: 1 });' --quiet
BACKUP_ID=$(get_backup_id ${TEST_NAME})
vlog "Backup: ${BACKUP_ID} completed"
# create db hash and get document counts
get_hashes_counts_before sharding
vlog "Log status before restore"
log_status ${TEST_DIR}/sh1_before_restore.log sharding
# drop roles / users / databases
cleanup sharding
check_cleanup
vlog "Log status after cleanup"
log_status ${TEST_DIR}/sh1_after_cleanup.log sharding
# do restore from selected storage
vlog "Doing restore of: ${BACKUP_ID}"
# stop the balancer so it doesn't change data on the shards before we record dbhash
run_cmd mongo ${MONGODB_URI}admin${MONGODB_OPTS} --eval 'db.adminCommand({ balancerStop: 1 });' --quiet
run_cmd pbmctl run restore --storage=${TEST_STORAGE} ${PBMCTL_OPTS} ${BACKUP_ID}
vlog "Restore from: ${BACKUP_ID} completed"
vlog "Log status after restore"
log_status ${TEST_DIR}/sh1_after_restore.log sharding
# create db hash and get document counts
get_hashes_counts_after sharding
check_after_restore
