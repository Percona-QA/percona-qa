# general replica sets test (long one)
. ${PQA_PATH}/pbm-tests/inc/common.sh

TEST_STORAGE="local-filesystem"
TEST_NAME="test-replica-${TEST_STORAGE}"
TEST_DIR="${TEST_RESULT_DIR}/results/${TEST_NAME}"
rm -rf ${TEST_DIR} && mkdir -p ${TEST_DIR}
EXTRA_STARTUP_OPTS=""
MONGODB_NODES="${HOST}:27017,${HOST}:27018,${HOST}:27019"
MONGODB_URI="mongodb://${MONGODB_USER}:${MONGODB_PASS}@${MONGODB_NODES}/"
MONGODB_OPTS="?replicaSet=rs1&authSource=admin"

start_replica
prepare_data replica
# run some load in background so that oplog also gets into backup
run_cmd ycsb load mongodb -s -P ${YCSB_PATH}/workloads/workloadb -p recordcount=100000 -p operationcount=100000 -threads 4 -p mongodb.url="${MONGODB_URI}ycsb_test3${MONGODB_OPTS}" -p mongodb.auth="true" >/dev/null 2>&1 &
sleep 5
# create backup to local filesystem
vlog "Doing backup"
run_cmd pbmctl run backup --description="${TEST_NAME}" --storage=${TEST_STORAGE} ${PBMCTL_OPTS}
BACKUP_ID=$(get_backup_id "${TEST_NAME}")
vlog "Backup: ${BACKUP_ID} completed"
# create db hash and get document counts
get_hashes_counts_before replica
vlog "Log status before restore"
log_status ${TEST_DIR}/rs1_before_restore.log replica
# drop roles / users / databases
cleanup replica
check_cleanup
vlog "Log status after cleanup"
log_status ${TEST_DIR}/rs1_after_cleanup.log replica
# do restore from local filesystem
vlog "Doing restore of: ${BACKUP_ID}"
run_cmd pbmctl run restore --storage=${TEST_STORAGE} ${PBMCTL_OPTS} ${BACKUP_ID}
vlog "Restore from: ${BACKUP_ID} completed"
vlog "Log status after restore"
log_status ${TEST_DIR}/rs1_after_restore.log replica
# create db hash and get document counts
get_hashes_counts_after replica
check_after_restore
