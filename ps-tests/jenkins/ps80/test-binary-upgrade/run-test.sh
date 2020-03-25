#!/usr/bin/env bash

set -o errexit
set -o xtrace

ROOT_DIR=$(cd $(dirname $0)/../../../../../percona-qa; pwd -P)
SOURCE_IMAGE=${1:-ubuntu:bionic}
UPGRADE_TEST=${2:-non_partition_test}
UPGRADE_FROM=${3:-5.7}
TEST_WORKDIR=${4:-/mnt/ps-upgrade-test}
PIPELINE_BUILD_NUMBER="$(cat PIPELINE_BUILD_NUMBER)"

PS_UPPER_DIR="ps-upper"
PS_LOWER_DIR="ps-lower"
PS_UPPER_DIR_FULL="${TEST_WORKDIR}/${PS_UPPER_DIR}"
PS_LOWER_DIR_FULL="${TEST_WORKDIR}/${PS_LOWER_DIR}"

mkdir -m 777 -p ${PS_UPPER_DIR_FULL}
mkdir -m 777 -p ${PS_LOWER_DIR_FULL}

cd ${PS_LOWER_DIR_FULL}
${ROOT_DIR}/get_download_link.sh --product=ps --version=${UPGRADE_FROM} --distribution=${SOURCE_IMAGE//:/-} --download
PS_TARBALL=$(ls *.tar.gz)
tar -xvf ${PS_TARBALL} --strip 1
rm -f ${PS_TARBALL}
cd -

cd ${PS_UPPER_DIR_FULL}
aws s3 cp --no-progress s3://ps-build-cache/jenkins-percona-server-8.0-pipeline-${PIPELINE_BUILD_NUMBER}/binary.tar.gz .
PS_TARBALL=$(ls *.tar.gz)
tar -xvf ${PS_TARBALL} --strip 1
rm -f ${PS_TARBALL}
cd -

docker run --rm \
    --mount type=bind,source=${ROOT_DIR},destination=/tmp/percona-qa \
    --mount type=bind,source=${TEST_WORKDIR},destination=/tmp/workdir \
    perconalab/ps-build:${SOURCE_IMAGE//[:\/]/-} \
    sh -c "
    set -o errexit
    set -o xtrace

    if [ -f /etc/redhat-release ]; then
      sudo yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
      sudo yum install -y sysbench
    else
      sudo wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
      sudo dpkg -i percona-release_latest.generic_all.deb && sudo rm percona-release_latest.generic_all.deb
      sudo apt update
      sudo apt install -y sysbench
    fi

    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "partition_test" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t partition_test
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "non_partition_test" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t non_partition_test
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "compression_test" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t compression_test
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "innodb_file_per_table_on" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t innodb_options_test -o --innodb_file_per_table=ON
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "innodb_file_per_table_off" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t innodb_options_test -o --innodb_file_per_table=OFF
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "replication_test_gtid" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t replication_test_gtid
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "replication_test_mts" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t replication_test_mts
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "replication_test" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t replication_test
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "replication_test_gtid_keyfile" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t replication_test_gtid -e -k file
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "replication_test_mts_keyfile" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t replication_test_mts -e -k file
    fi
    if [ "${UPGRADE_TEST}" = "all" -o "${UPGRADE_TEST}" = "replication_test_keyfile" ]; then
      /tmp/percona-qa/ps-upgrade-test_v1.sh -w /tmp/workdir -l /tmp/workdir/${PS_LOWER_DIR} -u /tmp/workdir/${PS_UPPER_DIR} -t replication_test -e -k file
    fi
"
