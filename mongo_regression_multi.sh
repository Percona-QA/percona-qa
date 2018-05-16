#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)
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

IFS=""
# Test suites
# --mode=files|suite (files= individual .js files)
# * Core JS: js or jsCore (same core/*.js)
# * Others: quota,jsPerf,disk,noPassthroughWithMongod,noPassthrough,parallel,concurrency,clone, repl,replSets,dur,auth,sharding,tool,aggregation, multiVersion,failPoint,ssl,sslSpecial,gle,slow1,slow2
# Other SE's we do not use: mmap_v1/rocksDB
s=('js' 'quota' 'jsPerf' 'disk' 'noPassthroughWithMongod' 'noPassthrough' 'parallel' 'concurrency' 'clone' 'repl' 'replSets' 'dur' 'auth' 'sharding' 'tool' 'aggregation' 'multiVersion' 'failPoint' 'ssl' 'sslSpecial' 'gle' 'slow1' 'slow2')
for i in "${s[@]}"; do
  echoit "Preparing to run test suite ${i}..."
  RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
  echoit "* Setting up work directory [/dev/shm/${RANDOMD}]..."
  WORKDIR="/dev/shm/${RANDOMD}"
  mkdir -p ${WORKDIR}
  PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
  echoit "* Running test suite ${i} on port ${PORT}..."
  screen -dmS ${i} sh -c "./buildscripts/smoke.py --mode=suite --port=$PORT --with-cleanbb --report-file=${WORKDIR}/smoke.py.log --smoke-db-prefix ${WORKDIR} --storageEngine=tokuft ${i}; exec bash"
  #PIDS=$!
  #WAIT_PIDS="${WAIT_PIDS} $PIDS"
done

echoit "Done!"
echoit "* Use screen -ls to see a list of active screen sessions"
echoit "* Use screen -d -r p{nr} (where {nr} is the screen session you want) to reconnect to an individual screen session"
echoit "List of sessions active:"
screen -ls

#echoit "Terminating all owned mongod instances..."
#${SCRIPT_PWD}/mongo_kill_procs.sh
