# general replica sets test (long one)
. ${PQA_PATH}/pbm-tests/inc/common.sh

TEST_STORAGE="minio-s3"
TEST_NAME="test-replica-${TEST_STORAGE}"
TEST_DIR="${TEST_RESULT_DIR}/results/${TEST_NAME}"
rm -rf ${TEST_DIR} && mkdir -p ${TEST_DIR}

MONGODB_NODES="localhost:27017,localhost:27018,localhost:27019"
MONGODB_URI="mongodb://${MONGODB_USER}:${MONGODB_PASS}@${MONGODB_NODES}/"
MONGODB_OPTS="?replicaSet=rs1&authSource=admin"

vlog "Starting test"
start_replica
prepare_data replica
# run some load in background so that oplog also gets into backup
ycsb_load "${MONGODB_URI}ycsb_test3${MONGODB_OPTS}" 100000 100000 4 >/dev/null 2>&1 &
# below is alternative good for debuging
# ${MONGODB_PATH}/bin/mongo ${MONGODB_URI}ycsb_test3${MONGODB_OPTS} --eval 'for(i=1; i <= 40000; i++) { db.usertable.insert({ _id: i, field1: "a", field0: "b", field7: "c" })}' --quiet >/dev/null 2>&1 &
sleep 5
# create backup to local filesystem
vlog "Doing backup"
pbmctl run backup --description="${TEST_NAME}" --storage=${TEST_STORAGE} ${PBMCTL_OPTS}
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
pbmctl run restore --storage=${TEST_STORAGE} ${PBMCTL_OPTS} ${BACKUP_ID}
vlog "Restore from: ${BACKUP_ID} completed"
vlog "Log status after restore"
log_status ${TEST_DIR}/rs1_after_restore.log replica
# create db hash and get document counts
get_hashes_counts_after replica
check_after_restore
stop_all_pbm
stop_all_mongo
sleep 5
# mv ${MONGODB_PATH}/nodes ${TEST_DIR}
vlog "Finished OK"
