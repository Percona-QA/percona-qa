export PBM_PATH=${HOME}/lab/pbm/pbm-latest
export YCSB_PATH=${HOME}/lab/psmdb/ycsb-mongodb-binding-0.15.0
export MONGODB_PATH=${HOME}/lab/psmdb/bin/percona-server-mongodb-4.0.10-5
export TEST_RESULT_DIR="${MONGODB_PATH}/pbm-test-run"
export STORAGE_ENGINE="wiredTiger"
export HOST="localhost"
export MONGODB_USER="dba"
export MONGODB_PASS="test1234"
export SAVE_STATE_BEFORE_RESTORE=0
export PBM_COORD_API_TOKEN="abcdefgh"
export PBM_COORD_ADDRESS="${HOST}:10001"
export PBMCTL_OPTS="--api-token=${PBM_COORD_API_TOKEN} --server-address=${PBM_COORD_ADDRESS}"
