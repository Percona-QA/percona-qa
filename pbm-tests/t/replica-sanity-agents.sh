# sanity check for PBM agents
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
sleep 3

check_pbm_agent ${HOST}:27017 listed
check_pbm_agent ${HOST}:27018 listed
check_pbm_agent ${HOST}:27019 listed
check_pbm_agent_count 3
stop_pbm_agent node1
check_pbm_agent ${HOST}:27017 not_listed
check_pbm_agent_count 2
start_pbm_agent node1
sleep 3
check_pbm_agent ${HOST}:27017 listed
check_pbm_agent_count 3
