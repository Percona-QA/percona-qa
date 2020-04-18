#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
TEST_SUITE=jsCore

echoit(){
  echo "[$(date +'%T')] [$SAVED] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] [$SAVED] $1" >> /${WORKDIR}/startup_mongo.log; fi
}

echoit "Checking Prerequisites..."
if [ ! -r mongod -o ! -r mongo -o ! -r mongos ]; then
  echo "Assert: required binaries ./mongod, ./mongo and ./mongos not present!"
  exit 1
fi

echoit "Terminating all owned mongod instances..."
${SCRIPT_PWD}/mongo_kill_procs.sh

echoit "Setting up work directory [/dev/shm/${RANDOMD}]..."
WORKDIR="/dev/shm/${RANDOMD}"
mkdir -p ${WORKDIR}

# Test suites
# --mode=files|suite (files= individual .js files)
# * Core JS: js or jsCore (same core/*.js)
# * Others: quota,jsPerf,disk,noPassthroughWithMongod,noPassthrough,parallel,concurrency,clone, repl,replSets,dur,auth,sharding,tool,aggregation, multiVersion,failPoint,ssl,sslSpecial,gle,slow1,slow2
# Other SE's we do not use: mmap_v1/rocksDB
echoit "Running test suite ${TEST_SUITE}..."
#buildscripts/smoke.py --mode=suite --port=$PORT --dont-start-mongod --with-cleanbb --report-file=${WORKDIR}/smoke.py.log --smoke-db-prefix ${WORKDIR} --storageEngine=tokuft jsCore
buildscripts/smoke.py --mode=suite --port=$PORT --with-cleanbb --report-file=${WORKDIR}/smoke.py.log --smoke-db-prefix ${WORKDIR} --storageEngine=tokuft jsCore

echoit "Terminating all owned mongod instances..."
${SCRIPT_PWD}/mongo_kill_procs.sh

