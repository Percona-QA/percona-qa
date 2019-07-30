#!/usr/bin/env bash

if [ $# -ne 4 ]; then
  echo "Illegal number of parameters"
  echo "Usage: docker-run.sh <pbm-repo> <pbm-branch> <test-suite> <mongodb-tarball-url>"
  echo "Test suite can be either 't' or 't/<some-test-name>'"
  exit 1
fi
PBM_REPO=$1
PBM_BRANCH=$2
TEST_SUITE=$3
MONGODB_TARBALL=$4

if [[ "${TEST_SUITE}" == *"/"* ]]; then
  RUN_EXTRA="-t /percona-qa/pbm-tests/${TEST_SUITE}"
else
  RUN_EXTRA="-s ${TEST_SUITE}"
fi

wget --quiet ${MONGODB_TARBALL}
tar -xf ${MONGODB_TARBALL##*/} && rm -f ${MONGODB_TARBALL##*/}
git clone https://github.com/Percona-QA/percona-qa.git --depth 1
export MONGODB_PATH="/$(ls -1|grep -E '^percona-server-mongodb*|^mongodb-*')"
export YCSB_PATH="/$(ls -1|grep -E '^ycsb*')"
export MGODATAGEN_PATH="/$(ls -1|grep -E '^mgodatagen*')"
export PBM_PATH="/pbm-latest"
export TEST_RESULT_DIR="/pbm-test-run"
export PATH=$PATH:/usr/local/go/bin

mkdir -p ${PBM_PATH}
mkdir -p ~/go/src/github.com/percona
export GOPATH=~/go
export PATH=$PATH:${GOPATH}
pushd ~/go/src/github.com/percona
git clone ${PBM_REPO} --branch ${PBM_BRANCH}
pushd percona-backup-mongodb
echo "PBM_REPO=${PBM_REPO}" | tee ${PBM_PATH}/pbm.properties
echo "PBM_BRANCH=${PBM_BRANCH}" | tee ${PBM_PATH}/pbm.properties
echo "PBM_COMMIT=$(git rev-parse --short HEAD)" | tee ${PBM_PATH}/pbm.properties
make clean && make
popd && popd
mv ~/go/src/github.com/percona/percona-backup-mongodb/pbmctl ${PBM_PATH}
mv ~/go/src/github.com/percona/percona-backup-mongodb/pbm-agent ${PBM_PATH}
mv ~/go/src/github.com/percona/percona-backup-mongodb/pbm-coordinator ${PBM_PATH}

cd percona-qa/pbm-tests
./run.sh -f ${RUN_EXTRA}

pushd ${TEST_RESULT_DIR}
subunit-1to2 test_results.subunit > test_results.subunit2
subunit2junitxml test_results.subunit2 -o test_results.xml
popd
