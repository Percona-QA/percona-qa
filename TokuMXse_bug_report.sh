#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script provides a handy template for logging TokuMXse bugs
# It expects one option: the failed test name. For example,
# ./TokuMXse_bug_report.sh 'disk/diskfull.js'

cat << EOF
== Issue observed
$1 fails against TokuMXse, but works against MMAPv1.

== Test to run (set in mongo_single_test.sh)
TEST_TO_RUN=$1

== Failure, Stack & Surrounding statements
.... INSERT STACK HERE .... <----------------------- TODO

== Full testcase
$ cd ~; git clone --depth=1 https://github.com/mariadb-corporation/mariadb-qa.git
$ [Optional] ~/mariadb-qa/build_tokumx.sh	# Build debug TokuMXse Mongo build
$ [Optional] cd /tmp/tokumxse_debug_build/tokumxse	# cd to the directory that has mongo,mongod,mongos
$ vi ~/mariadb-qa/mongo_single_test.sh	# Set the TEST_TO_RUN as listed above under 'Test to run'
$ ~/mariadb-qa/mongo_single_test.sh	# Output (except for path) should look similar to;
[...] > 1 tests succeeded for MMAPv1 on $1
[...] > 0 tests succeeded for TokuMXse on $1

== Full information available
All relevant files/logs etc. are in the /dev/shm/{nr} work directory listed in the script's output.

Directory contents for the /dev/shm/{nr} directory are as follows;
FT_RUN_DATA The data directory from the TokuMXse test
MMAP_RUN_DATA The data directory from the MMAPv1 test
single_test_mongo.log	The output from mongo_single_test.sh (as shown above)
smoke.py_FT.log.report	smoke.py report output for TokuMXse test (--report-file=)
smoke.py_MMAP.log.report	smoke.py report output for MMAPv1 test (--report-file=)
smoke.py_FT.log	smoke.py full on-screen output for TokuMXse test
smoke.py_MMAP.log	smoke.py full on-screen output for MMAPv1 test
EOF
