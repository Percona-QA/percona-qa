#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

BASEDIR=""
LAYOUT=""
STORAGE_ENGINE="wiredTiger"

if [ -z $1 ]; then
  echo "You need to specify at least one of the options for layout: --single, --rs, --sh!"
  exit 1
fi

# Check if we have a functional getopt(1)
if ! getopt --test
then
    go_out="$(getopt --options=mrshe:b: \
        --longoptions=single,rs,sh,help,storageEngine:,bindir: \
        --name="$(basename "$0")" -- "$@")"
    test $? -eq 0 || exit 1
    eval set -- $go_out
fi

for arg
do
  case "$arg" in
  -- ) shift; break;;
  -m | --single )
    shift
    LAYOUT="single"
    ;;
  -r | --rs )
    shift
    LAYOUT="rs"
    ;;
  -s | --sh )
    shift
    LAYOUT="sh"
    ;;
  -h | --help )
    shift
    echo -e "\nThis script can be used to setup single instance, replica set or sharded cluster of mongod or psmdb from binary tarball."
    echo -e "By default it should be run from mongodb/psmdb base directory."
    echo -e "Setup is located in the \"nodes\" subdirectory.\n"
    echo -e "Options:"
    echo -e "-m, --single\t\t run single instance"
    echo -e "-r, --rs\t\t run replica set (3 nodes)"
    echo -e "-s, --sh\t\t run sharding cluster (2 replica sets with 3 nodes each)"
    echo -e "-e, --storageEngine\t specify storage engine for data nodes (wiredTiger, rocksdb, mmapv1)"
    echo -e "-b, --bindir\t\t specify binary directory if running from some other location (this should end with /bin)"
    echo -e "-h, --help\t\t this help"
    exit 0
    ;;
  -e | --storageEngine )
    shift
    STORAGE_ENGINE="$1"
    shift
    ;;
  -b | --bindir )
    shift
    BINDIR="$1"
    shift
    ;;
  esac
done

BASEDIR="$(pwd)"
if [ -z "${BINDIR}" ]; then
  BINDIR="${BASEDIR}/bin"
fi
NODESDIR="${BASEDIR}/nodes"

if [ ! -x "${BINDIR}/mongod" ]; then
  echo "${BINDIR}/mongod doesn't exists or is not executable!"
  exit 1
elif [ ! -x "${BINDIR}/mongos" ]; then
  echo "${BINDIR}/mongos doesn't exists or is not executable!"
  exit 1
elif [ ! -x "${BINDIR}/mongo" ]; then
  echo "${BINDIR}/mongo doesn't exists or is not executable!"
  exit 1
fi

if [ -d ${NODESDIR} ]; then
  echo "${NODESDIR} already exists"
  exit 1
else
  mkdir ${NODESDIR}
fi

start_mongod(){
  local NDIR="$1"
  local RS="$2"
  local PORT="$3"
  local SE="$4"
  local EXTRA="$5"
  local RS_OPT=""
  if [ ${RS} != "nors" ]; then
    EXTRA="${EXTRA} --replSet ${RS}"
  fi
  if [ "${SE}" == "wiredTiger" ]; then
    EXTRA="${EXTRA} --wiredTigerCacheSizeGB 1"
  elif [ "${SE}" == "wiredTiger" ]; then
    EXTRA="${EXTRA} --rocksdbCacheSizeGB 1"
  fi
  mkdir -p ${NDIR}/db
  echo "#!/usr/bin/env bash" > ${NDIR}/start.sh
  echo "echo \"Starting mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/start.sh
  echo "${BINDIR}/mongod --port ${PORT} --storageEngine ${SE} --dbpath ${NDIR}/db --logpath ${NDIR}/mongod.log --fork ${EXTRA} > /dev/null" >> ${NDIR}/start.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/cl.sh
  echo "${BINDIR}/mongo localhost:${PORT} \$@" >> ${NDIR}/cl.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/stop.sh
  echo "echo \"Stopping mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/stop.sh
  echo "${BINDIR}/mongo localhost:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})'" >> ${NDIR}/stop.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/wipe.sh
  echo "${NDIR}/stop.sh" >> ${NDIR}/wipe.sh
  echo "rm -rf ${NDIR}/db.PREV" >> ${NDIR}/wipe.sh
  echo "rm -f ${NDIR}/mongod.log.PREV" >> ${NDIR}/wipe.sh
  echo "rm -f ${NDIR}/mongod.log.2*" >> ${NDIR}/wipe.sh
  echo "mv ${NDIR}/mongod.log ${NDIR}/mongod.log.PREV" >> ${NDIR}/wipe.sh
  echo "mv ${NDIR}/db ${NDIR}/db.PREV" >> ${NDIR}/wipe.sh
  echo "mkdir -p ${NDIR}/db" >> ${NDIR}/wipe.sh
  echo "touch ${NDIR}/mongod.log" >> ${NDIR}/wipe.sh
  chmod +x ${NDIR}/start.sh
  chmod +x ${NDIR}/cl.sh
  chmod +x ${NDIR}/stop.sh
  chmod +x ${NDIR}/wipe.sh
  ${NDIR}/start.sh
}

start_replicaset(){
  local RSDIR="$1"
  local RSNAME="$2"
  local RSBASEPORT="$3"
  local EXTRA="$4"
  mkdir -p "${RSDIR}"
  echo "=== Starting replica set: ${RSNAME} ==="
  for i in 1 2 3; do
    start_mongod "${RSDIR}/node${i}" "${RSNAME}" "$(($RSBASEPORT + ${i} - 1))" "${STORAGE_ENGINE}" "${EXTRA}"
  done
  sleep 5
  echo "#!/usr/bin/env bash" > ${RSDIR}/init_rs.sh
  echo "echo \"Initializing replica set: ${RSNAME}\"" >> ${RSDIR}/init_rs.sh
  echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'rs.initiate({_id:\"${RSNAME}\", members: [{\"_id\":1, \"host\":\"localhost:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"localhost:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"localhost:$(($RSBASEPORT + 2))\"}]})'" >> ${RSDIR}/init_rs.sh
  echo "#!/usr/bin/env bash" > ${RSDIR}/stop_rs.sh
  echo "echo \"=== Stopping replica set: ${RSNAME} ===\"" >> ${RSDIR}/stop_rs.sh
  for cmd in $(find ${RSDIR} -name stop.sh); do
    echo "${cmd}" >> ${RSDIR}/stop_rs.sh
  done
  echo "#!/usr/bin/env bash" > ${RSDIR}/start_rs.sh
  echo "echo \"=== Starting replica set: ${RSNAME} ===\"" >> ${RSDIR}/start_rs.sh
  for cmd in $(find ${RSDIR} -name start.sh); do
    echo "${cmd}" >> ${RSDIR}/start_rs.sh
  done
  echo "#!/usr/bin/env bash" > ${RSDIR}/cl_primary.sh
  echo "PRIMARY=\$(${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'db.runCommand(\"ismaster\").primary' | tail -n1)" >> ${RSDIR}/cl_primary.sh
  echo "${BINDIR}/mongo \${PRIMARY} \$@" >> ${RSDIR}/cl_primary.sh
  chmod +x ${RSDIR}/init_rs.sh
  chmod +x ${RSDIR}/start_rs.sh
  chmod +x ${RSDIR}/stop_rs.sh
  chmod +x ${RSDIR}/cl_primary.sh
  ${RSDIR}/init_rs.sh
}

if [ "${LAYOUT}" == "single" ]; then
  mkdir -p "${NODESDIR}"
  start_mongod "${NODESDIR}" "nors" "27017" "${STORAGE_ENGINE}"
fi

if [ "${LAYOUT}" == "rs" ]; then
  mkdir -p "${NODESDIR}"
  start_replicaset "${NODESDIR}" "rs1" "27017"
fi

if [ "${LAYOUT}" == "sh" ]; then
  SHPORT=27017
  CFGPORT=27027
  RS1PORT=27018
  RS2PORT=28018
  SHNAME="sh1"
  RS1NAME="rs1"
  RS2NAME="rs2"
  CFGRSNAME="config"
  mkdir -p "${NODESDIR}/${RS1NAME}"
  mkdir -p "${NODESDIR}/${RS2NAME}"
  mkdir -p "${NODESDIR}/${CFGRSNAME}"
  mkdir -p "${NODESDIR}/${SHNAME}"

  echo "=== Configuring sharding cluster: ${SHNAME} ==="
  # setup config replicaset (1 node)
  echo "=== Starting config server replica set: ${CFGRSNAME} ==="
  start_mongod "${NODESDIR}/${CFGRSNAME}" "config" "${CFGPORT}" "wiredTiger" "--configsvr"
  echo "Initializing config server replica set: ${CFGRSNAME}"
  ${BINDIR}/mongo localhost:${CFGPORT} --quiet --eval "rs.initiate({_id:\"${CFGRSNAME}\", members: [{_id:1, \"host\":\"localhost:${CFGPORT}\"}]})"
  # setup 2 data replica sets
  start_replicaset "${NODESDIR}/${RS1NAME}" "${RS1NAME}" "${RS1PORT}" "--shardsvr"
  start_replicaset "${NODESDIR}/${RS2NAME}" "${RS2NAME}" "${RS2PORT}" "--shardsvr"
  # create managing scripts
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "echo \"=== Starting sharding server: ${SHNAME} on port ${SHPORT} ===\"" >> ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "${BINDIR}/mongos --port ${SHPORT} --configdb ${CFGRSNAME}/localhost:${CFGPORT} --logpath ${NODESDIR}/${SHNAME}/mongos.log --fork >/dev/null" >> ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/cl_mongos.sh
  echo "${BINDIR}/mongo localhost:${SHPORT} \$@" >> ${NODESDIR}/${SHNAME}/cl_mongos.sh
  ln -s ${NODESDIR}/${SHNAME}/cl_mongos.sh ${NODESDIR}/cl_mongos.sh
  echo "echo \"=== Stopping sharding cluster: ${SHNAME} ===\"" >> ${NODESDIR}/stop_all.sh
  for cmd in $(find ${NODESDIR}/${RSNAME} -name stop.sh); do
    echo "${cmd}" >> ${NODESDIR}/stop_all.sh
  done
  echo "${NODESDIR}/${SHNAME}/stop_mongos.sh" >> ${NODESDIR}/stop_all.sh
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "echo \"Stopping mongos on port: ${SHPORT}\"" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "${BINDIR}/mongo localhost:${SHPORT}/admin --quiet --eval 'db.shutdownServer({force:true})'" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "#!/usr/bin/env bash" > ${NODESDIR}/start_all.sh
  echo "echo \"Starting sharding cluster on port: ${SHPORT}\"" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${CFGRSNAME}/start.sh" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${RS1NAME}/start_rs.sh" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${RS2NAME}/start_rs.sh" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${SHNAME}/start_mongos.sh" >> ${NODESDIR}/start_all.sh
  chmod +x ${NODESDIR}/${SHNAME}/start_mongos.sh
  chmod +x ${NODESDIR}/${SHNAME}/stop_mongos.sh
  chmod +x ${NODESDIR}/${SHNAME}/cl_mongos.sh
  chmod +x ${NODESDIR}/start_all.sh
  chmod +x ${NODESDIR}/stop_all.sh
  # start mongos
  ${NODESDIR}/${SHNAME}/start_mongos.sh
  # add Shards to the Cluster
  echo "Adding shards to the cluster..."
  sleep 20
  ${BINDIR}/mongo localhost:${SHPORT} --quiet --eval "sh.addShard(\"${RS1NAME}/localhost:${RS1PORT}\")"
  ${BINDIR}/mongo localhost:${SHPORT} --quiet --eval "sh.addShard(\"${RS2NAME}/localhost:${RS2PORT}\")"
  echo -e "\n>>> Enable sharding on specific database with: sh.enableSharding(\"<database>\") <<<"
  echo -e ">>> Shard a collection with: sh.shardCollection(\"<database>.<collection>\", { <key> : <direction> } ) <<<\n"
fi

