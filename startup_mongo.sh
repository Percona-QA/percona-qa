#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Main user configurable variables
ENGINE=tokuft      #  Storage Engine to use: tokuft, mmapv1 or wiredTiger. Use db.serverStatus()["storageEngine"]["name"] at the CLI to check

# Internal variables, do not change
SCRIPT_PWD=$(cd `dirname $0` && pwd)
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] [$SAVED] $1" >> /${WORKDIR}/startup_mongo.log; fi
}

echoit "Checking Prerequisites..."
if [ ! -r mongod -o ! -r mongo -o ! -r mongos ]; then
  echo "Assert: required binaries ./mongod, ./mongo and ./mongos not present!"
  exit 1
fi
ENGINE_CHECK_OK=0
if [ "${ENGINE}" == "tokuft" ]; then ENGINE_CHECK_OK=1; fi
if [ "${ENGINE}" == "mmapv1" ]; then ENGINE_CHECK_OK=1; fi
if [ "${ENGINE}" == "wiredTiger" ]; then ENGINE_CHECK_OK=1; fi
if [ ${ENGINE_CHECK_OK} -eq 0 ]; then  
  echo "Assert: ENGINE seems to be set to an incorrect value (${ENGINE})!"
  exit 1
fi

echoit "Terminating all owned mongod instances..."
${SCRIPT_PWD}/kill_mongo_procs.sh

echoit "Setting up work directory [/dev/shm/${RANDOMD}]..."
WORKDIR="/dev/shm/${RANDOMD}"
mkdir -p ${WORKDIR}

echoit "Starting up mongod [Port ${PORT}]..."
./mongod --port ${PORT} --dbpath ${WORKDIR} --setParameter enableTestCommands=1 --storageEngine ${ENGINE} --noauth &
sleep 1

echoit "Testing mongo CLI can connect..."
./mongo --port ${PORT} --shell

echoit "Terminating all owned mongod instances..."
${SCRIPT_PWD}/kill_mongo_procs.sh
