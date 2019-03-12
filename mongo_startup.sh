#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

BASEDIR=""
LAYOUT=""
STORAGE_ENGINE="wiredTiger"
MONGOD_EXTRA=""
MONGOS_EXTRA=""
CONFIG_EXTRA=""
RS_ARBITER=0
CIPHER_MODE="AES256-CBC"
ENCRYPTION="no"
PBMDIR=""
AUTH=""
MONGO_USER="dba"
MONGO_PASS="test1234"

if [ -z $1 ]; then
  echo "You need to specify at least one of the options for layout: --single, --rSet, --sCluster or use --help!"
  exit 1
fi

# Check if we have a functional getopt(1)
if ! getopt --test
then
    go_out="$(getopt --options=mrsahe:b:tc:px \
        --longoptions=single,rSet,sCluster,arbiter,help,storageEngine:,binDir:,mongodExtra:,mongosExtra:,configExtra:,encrypt,cipherMode:,pbmDir:,auth \
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
  -r | --rSet )
    shift
    LAYOUT="rs"
    ;;
  -s | --sCluster )
    shift
    LAYOUT="sh"
    ;;
  -a | --arbiter )
    shift
    RS_ARBITER=1
    ;;
  -h | --help )
    shift
    echo -e "\nThis script can be used to setup single instance, replica set or sharded cluster of mongod or psmdb from binary tarball."
    echo -e "By default it should be run from mongodb/psmdb base directory."
    echo -e "Setup is located in the \"nodes\" subdirectory.\n"
    echo -e "Options:"
    echo -e "-m, --single\t\t\t run single instance"
    echo -e "-r, --rSet\t\t\t run replica set (3 nodes)"
    echo -e "-s, --sCluster\t\t\t run sharding cluster (2 replica sets with 3 nodes each)"
    echo -e "-a, --arbiter\t\t\t instead of 3 nodes in replica set add 2 nodes and 1 arbiter"
    echo -e "-e<se>, --storageEngine=<se>\t specify storage engine for data nodes (wiredTiger, rocksdb, mmapv1)"
    echo -e "-b<path>, --binDir=<path>\t specify binary directory if running from some other location (this should end with /bin)"
    echo -e "--mongodExtra=\"...\"\t\t specify extra options to pass to mongod"
    echo -e "--mongosExtra=\"...\"\t\t specify extra options to pass to mongos"
    echo -e "--configExtra=\"...\"\t\t specify extra options to pass to config server"
    echo -e "-t, --encrypt\t\t\t enable data at rest encryption (wiredTiger only)"
    echo -e "-c<mode>, --cipherMode=<mode>\t specify cipher mode for encryption (AES256-CBC or AES256-GCM)"
    echo -e "-p<path>, --pbmDir=<path>\t if specified enables Percona Backup for MongoDB (starts agents and coordinator)"
    echo -e "-h, --help\t\t\t this help"
    exit 0
    ;;
  -e | --storageEngine )
    shift
    STORAGE_ENGINE="$1"
    shift
    ;;
  --mongodExtra )
    shift
    MONGOD_EXTRA="$1"
    shift
    ;;
  --mongosExtra )
    shift
    MONGOS_EXTRA="$1"
    shift
    ;;
  --configExtra )
    shift
    CONFIG_EXTRA="$1"
    shift
    ;;
  -t | --encrypt )
    shift
    ENCRYPTION="keyfile"
    ;;
  -c | --cipherMode )
    shift
    CIPHER_MODE="$1"
    shift
    ;;
  -b | --binDir )
    shift
    BINDIR="$1"
    shift
    ;;
  -p | --pbmDir )
    shift
    PBMDIR="$1"
    shift
    ;;
  -x | --auth )
    shift
    AUTH="--username=${MONGO_USER} --password=${MONGO_PASS} --authenticationDatabase=admin"
    ;;
  esac
done

if [ "${STORAGE_ENGINE}" != "wiredTiger" -a "${ENCRYPTION}" != "no" ]; then
  echo "ERROR: Data at rest encryption is possible only with wiredTiger storage engine!"
  exit 1
fi

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

if [ ! -z "${PBMDIR}" -a ! -x "${PBMDIR}/pbmctl" ]; then
  echo "${PBMDIR}/pbmctl doesn't exists or is not executable!"
  exit 1
elif [ ! -z "${PBMDIR}" -a ! -x "${PBMDIR}/pbm-agent" ]; then
  echo "${PBMDIR}/pbm-agent doesn't exists or is not executable!"
  exit 1
elif [ ! -z "${PBMDIR}" -a ! -x "${PBMDIR}/pbm-coordinator" ]; then
  echo "${PBMDIR}/pbm-coordinator doesn't exists or is not executable!"
  exit 1
fi

if [ -d ${NODESDIR} ]; then
  echo "${NODESDIR} already exists"
  exit 1
else
  mkdir ${NODESDIR}
fi

echo "MONGO_USER=\"${MONGO_USER}\"" > ${NODESDIR}/COMMON
echo "MONGO_PASS=\"${MONGO_PASS}\"" >> ${NODESDIR}/COMMON
echo "AUTH=\"\"" >> ${NODESDIR}/COMMON
if [ ! -z "${AUTH}" ]; then
  openssl rand -base64 756 > ${NODESDIR}/keyFile
  chmod 400 ${NODESDIR}/keyFile
  MONGOD_EXTRA="${MONGOD_EXTRA} --keyFile ${NODESDIR}/keyFile"
  MONGOS_EXTRA="${MONGOS_EXTRA} --keyFile ${NODESDIR}/keyFile"
  CONFIG_EXTRA="${CONFIG_EXTRA} --keyFile ${NODESDIR}/keyFile"
fi

VERSION_FULL=$(${BINDIR}/mongod --version|head -n1|sed 's/db version v//')
VERSION_MAJOR=$(echo "${VERSION_FULL}"|grep -o '^.\..')

start_pbm_coordinator(){
  if [ ! -z "${PBMDIR}" ]; then
    mkdir -p "${NODESDIR}/pbm-coordinator/workdir"
    mkdir -p "${NODESDIR}/backup"

    # Create startup script for the pbm-coordinator
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    echo "echo \"=== Starting pbm-coordinator on port: 10000 ===\"" >> ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    echo "${PBMDIR}/pbm-coordinator --work-dir=${NODESDIR}/pbm-coordinator/workdir --log-file=${NODESDIR}/pbm-coordinator/pbm-coordinator.log 1>${NODESDIR}/pbm-coordinator/stdout.log 2>${NODESDIR}/pbm-coordinator/stderr.log &" >> ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    chmod +x ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh

    # Create stop script for the pbm-coordinator
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh
    echo "killall pbm-coordinator" >> ${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh
    chmod +x ${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh

    # create symlinks to PBM binaries
    ln -s ${PBMDIR}/pbmctl ${NODESDIR}/pbmctl
    ln -s ${PBMDIR}/pbm-coordinator ${NODESDIR}/pbm-coordinator

    # create startup/stop scripts for the whole PBM setup
    echo "#!/usr/bin/env bash" > ${NODESDIR}/start_pbm.sh
    echo "${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh" >> ${NODESDIR}/start_pbm.sh
    echo "sleep 5" >> ${NODESDIR}/start_pbm.sh
    chmod +x ${NODESDIR}/start_pbm.sh

    echo "#!/usr/bin/env bash" > ${NODESDIR}/stop_pbm.sh
    echo "killall pbm-agent pbm-coordinator" >> ${NODESDIR}/stop_pbm.sh
    chmod +x ${NODESDIR}/stop_pbm.sh
  fi
}

start_pbm_agent(){
  local NDIR="$1"
  local RS="$2"
  local NPORT="$3"
  local ITYPE="$4"

  local MAUTH=""
  local MREPLICASET=""
  if [ ! -z "${AUTH}" ]; then
    MAUTH="--mongodb-username=\${MONGO_USER} --mongodb-password=\${MONGO_PASS}"
  fi
  if [ "${RS}" != "nors" ]; then
    MREPLICASET="--mongodb-replicaset=${RS}"
  fi

  if [ ! -z "${PBMDIR}" ]; then
    mkdir -p "${NDIR}/pbm-agent"
    # Create storages config for node agent
    echo "local-filesystem:" > ${NDIR}/pbm-agent/storages-config.yaml
    echo "  type: filesystem" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "  filesystem:" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "    path: ${NODESDIR}/backup" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "s3-us-west:" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "  type: s3" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "  s3:" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "    region: us-west" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "    endpointUrl: http://localhost:9000" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "    bucket: pbm" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "    credentials:" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "      access-key-id: ${MINIO_ACCESS_KEY_ID}" >> ${NDIR}/pbm-agent/storages-config.yaml
    echo "      secret-access-key: ${MINIO_SECRET_ACCESS_KEY}" >> ${NDIR}/pbm-agent/storages-config.yaml

    # Create startup script for the agent on the node
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "source ${NODESDIR}/COMMON" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "echo \"Starting pbm-agent for mongod on port: ${NPORT} replicaset: ${RS} \"" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${PBMDIR}/pbm-agent --mongodb-host=localhost --mongodb-port=${NPORT} --storages-config=${NDIR}/pbm-agent/storages-config.yaml --server-address=127.0.0.1:10000 --log-file=${NDIR}/pbm-agent/pbm-agent.log --pid-file=${NDIR}/pbm-agent/pbm-agent.pid ${MREPLICASET} ${MAUTH} 1>${NDIR}/pbm-agent/stdout.log 2>${NDIR}/pbm-agent/stderr.log &" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${NDIR}/pbm-agent/start_pbm_agent.sh" >> ${NODESDIR}/start_pbm.sh
    ${NDIR}/pbm-agent/start_pbm_agent.sh

    # Create stop script for the agent on the node
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/stop_pbm_agent.sh
    echo "kill \$(cat ${NDIR}/pbm-agent/pbm-agent.pid)" >> ${NDIR}/pbm-agent/stop_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/stop_pbm_agent.sh

    # create a symlink for pbm-agent binary
    ln -s ${PBMDIR}/pbm-agent ${NDIR}/pbm-agent/pbm-agent
  fi
}

start_mongod(){
  local NDIR="$1"
  local RS="$2"
  local PORT="$3"
  local SE="$4"
  local EXTRA="$5"
  local RS_OPT=""
  mkdir -p ${NDIR}/db
  if [ ${RS} != "nors" ]; then
    EXTRA="${EXTRA} --replSet ${RS}"
  fi
  if [ "${SE}" == "wiredTiger" ]; then
    EXTRA="${EXTRA} --wiredTigerCacheSizeGB 1"
    if [ "${ENCRYPTION}" = "keyfile" ]; then
      openssl rand -base64 32 > ${NDIR}/mongodb-keyfile
      chmod 600 ${NDIR}/mongodb-keyfile
      EXTRA="${EXTRA} --enableEncryption --encryptionKeyFile ${NDIR}/mongodb-keyfile --encryptionCipherMode ${CIPHER_MODE}"
    fi
  elif [ "${SE}" == "rocksdb" ]; then
    EXTRA="${EXTRA} --rocksdbCacheSizeGB 1"
    if [ "${VERSION_MAJOR}" = "3.6" ]; then
      EXTRA="${EXTRA} --useDeprecatedMongoRocks"
    fi
  fi

  echo "#!/usr/bin/env bash" > ${NDIR}/start.sh
  echo "source ${NODESDIR}/COMMON" >> ${NDIR}/start.sh
  echo "echo \"Starting mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/start.sh
  echo "ENABLE_AUTH=\"\"" >> ${NDIR}/start.sh
  echo "if [ ! -z \"\${AUTH}\" ]; then ENABLE_AUTH=\"--auth\"; fi" >> ${NDIR}/start.sh
  echo "${BINDIR}/mongod \${ENABLE_AUTH} --port ${PORT} --storageEngine ${SE} --dbpath ${NDIR}/db --logpath ${NDIR}/mongod.log --fork ${EXTRA} > /dev/null" >> ${NDIR}/start.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/cl.sh
  echo "source ${NODESDIR}/COMMON" >> ${NDIR}/cl.sh
  echo "${BINDIR}/mongo localhost:${PORT} \${AUTH} \$@" >> ${NDIR}/cl.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/stop.sh
  echo "source ${NODESDIR}/COMMON" >> ${NDIR}/stop.sh
  echo "echo \"Stopping mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/stop.sh
  echo "${BINDIR}/mongo localhost:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH}" >> ${NDIR}/stop.sh
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
  if [ ${RS_ARBITER} = 0 ]; then
    if [ "${STORAGE_ENGINE}" == "inMemory" ]; then
      echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'rs.initiate({_id:\"${RSNAME}\", writeConcernMajorityJournalDefault: false, members: [{\"_id\":1, \"host\":\"localhost:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"localhost:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"localhost:$(($RSBASEPORT + 2))\"}]})'" >> ${RSDIR}/init_rs.sh
    else
      echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'rs.initiate({_id:\"${RSNAME}\", members: [{\"_id\":1, \"host\":\"localhost:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"localhost:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"localhost:$(($RSBASEPORT + 2))\"}]})'" >> ${RSDIR}/init_rs.sh
    fi
  else
    echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'rs.initiate({_id:\"${RSNAME}\", members: [{\"_id\":1, \"host\":\"localhost:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"localhost:$(($RSBASEPORT + 1))\"}]})'" >> ${RSDIR}/init_rs.sh
    echo "sleep 20" >> ${RSDIR}/init_rs.sh
    echo "PRIMARY=\$(${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'db.runCommand(\"ismaster\").primary' | tail -n1)" >> ${RSDIR}/init_rs.sh
    echo "${BINDIR}/mongo \${PRIMARY} --quiet --eval 'rs.addArb(\"localhost:$(($RSBASEPORT + 2))\")'" >> ${RSDIR}/init_rs.sh
  fi
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
  echo "source ${NODESDIR}/COMMON" >> ${RSDIR}/cl_primary.sh
  if [ "${VERSION_MAJOR}" = "3.2" ]; then
    echo "PRIMARY=\$(${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet --eval 'db.runCommand(\"ismaster\").primary' | tail -n1) \${AUTH}" >> ${RSDIR}/cl_primary.sh
    echo "${BINDIR}/mongo \${PRIMARY} \${AUTH} \$@" >> ${RSDIR}/cl_primary.sh
  else
    echo "${BINDIR}/mongo \"mongodb://localhost:${RSBASEPORT},localhost:$(($RSBASEPORT + 1)),localhost:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}\" \${AUTH} \$@" >> ${RSDIR}/cl_primary.sh
  fi
  chmod +x ${RSDIR}/init_rs.sh
  chmod +x ${RSDIR}/start_rs.sh
  chmod +x ${RSDIR}/stop_rs.sh
  chmod +x ${RSDIR}/cl_primary.sh
  ${RSDIR}/init_rs.sh

  if [ ! -z "${AUTH}" ]; then
    sleep 10
    ${BINDIR}/mongo "mongodb://localhost:${RSBASEPORT},localhost:$(($RSBASEPORT + 1)),localhost:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}" --quiet --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] });"
    sed -i '/AUTH=/c\AUTH="--username=${MONGO_USER} --password=${MONGO_PASS} --authenticationDatabase=admin"' ${NODESDIR}/COMMON
  fi

  # start PBM agents for replica set nodes
  for i in 1 2 3; do
    if [ ${RS_ARBITER} != 1 -o ${i} -lt 3 ]; then
      start_pbm_agent "${RSDIR}/node${i}" "${RSNAME}" "$(($RSBASEPORT + ${i} - 1))" "mongod"
    fi
  done
}

# start PBM coordinator if PBM directory specified
start_pbm_coordinator

if [ "${LAYOUT}" == "single" ]; then
  mkdir -p "${NODESDIR}"
  start_mongod "${NODESDIR}" "nors" "27017" "${STORAGE_ENGINE}" "${MONGOD_EXTRA}"

  if [[ "${MONGOD_EXTRA}" == *"replSet"* ]]; then
    ${BINDIR}/mongo localhost:27017 --quiet --eval 'rs.initiate()'
    sleep 5
  fi

  if [ ! -z "${AUTH}" ]; then
    ${BINDIR}/mongo localhost:27017/admin --quiet --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] });"
    ${NODESDIR}/stop.sh
    sed -i '/AUTH=/c\AUTH="--username=${MONGO_USER} --password=${MONGO_PASS} --authenticationDatabase=admin"' ${NODESDIR}/COMMON
    sleep 5
    ${NODESDIR}/start.sh
  fi

  start_pbm_agent "${NODESDIR}" "rs1" "27017" "mongod"
fi

if [ "${LAYOUT}" == "rs" ]; then
  mkdir -p "${NODESDIR}"
  # start replica set
  start_replicaset "${NODESDIR}" "rs1" "27017" "${MONGOD_EXTRA}"
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
  start_mongod "${NODESDIR}/${CFGRSNAME}" "config" "${CFGPORT}" "wiredTiger" "--configsvr ${CONFIG_EXTRA}"
  echo "Initializing config server replica set: ${CFGRSNAME}"
  ${BINDIR}/mongo localhost:${CFGPORT} --quiet --eval "rs.initiate({_id:\"${CFGRSNAME}\", members: [{_id:1, \"host\":\"localhost:${CFGPORT}\"}]})"
  # this is needed in 3.6 for MongoRocks since it doesn't support FCV 3.6 and config servers control this in sharding setup
  if [ "${STORAGE_ENGINE}" = "rocksdb" -a "${VERSION_MAJOR}" = "3.6" ]; then
    sleep 15
    ${BINDIR}/mongo localhost:${CFGPORT} --quiet --eval "db.adminCommand({ setFeatureCompatibilityVersion: \"3.4\" });"
  fi

  # setup 2 data replica sets
  start_replicaset "${NODESDIR}/${RS1NAME}" "${RS1NAME}" "${RS1PORT}" "--shardsvr ${MONGOD_EXTRA}"
  start_replicaset "${NODESDIR}/${RS2NAME}" "${RS2NAME}" "${RS2PORT}" "--shardsvr ${MONGOD_EXTRA}"

  # create managing scripts
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "echo \"=== Starting sharding server: ${SHNAME} on port ${SHPORT} ===\"" >> ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "${BINDIR}/mongos --port ${SHPORT} --configdb ${CFGRSNAME}/localhost:${CFGPORT} --logpath ${NODESDIR}/${SHNAME}/mongos.log --fork "$MONGOS_EXTRA" >/dev/null" >> ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/cl_mongos.sh
  echo "source ${NODESDIR}/COMMON" >> ${NODESDIR}/${SHNAME}/cl_mongos.sh
  echo "${BINDIR}/mongo localhost:${SHPORT} \${AUTH} \$@" >> ${NODESDIR}/${SHNAME}/cl_mongos.sh
  ln -s ${NODESDIR}/${SHNAME}/cl_mongos.sh ${NODESDIR}/cl_mongos.sh
  echo "echo \"=== Stopping sharding cluster: ${SHNAME} ===\"" >> ${NODESDIR}/stop_all.sh
  echo "${NODESDIR}/${SHNAME}/stop_mongos.sh" >> ${NODESDIR}/stop_all.sh
  for cmd in $(find ${NODESDIR}/${RSNAME} -name stop.sh); do
    echo "${cmd}" >> ${NODESDIR}/stop_all.sh
  done
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "source ${NODESDIR}/COMMON" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "echo \"Stopping mongos on port: ${SHPORT}\"" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "${BINDIR}/mongo localhost:${SHPORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH}" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
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
  if [ ! -z "${AUTH}" ]; then
    ${BINDIR}/mongo localhost:${SHPORT}/admin --quiet --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\", \"userAdminAnyDatabase\", \"clusterAdmin\" ] });"
  fi
  # add Shards to the Cluster
  echo "Adding shards to the cluster..."
  sleep 20
  ${BINDIR}/mongo localhost:${SHPORT} --quiet --eval "sh.addShard(\"${RS1NAME}/localhost:${RS1PORT}\")" ${AUTH}
  ${BINDIR}/mongo localhost:${SHPORT} --quiet --eval "sh.addShard(\"${RS2NAME}/localhost:${RS2PORT}\")" ${AUTH}
  echo -e "\n>>> Enable sharding on specific database with: sh.enableSharding(\"<database>\") <<<"
  echo -e ">>> Shard a collection with: sh.shardCollection(\"<database>.<collection>\", { <key> : <direction> } ) <<<\n"

  # start a PBM agent on the config replica set node (needed here because auth is enabled through mongos)
  start_pbm_agent "${NODESDIR}/${CFGRSNAME}" "${CFGRSNAME}" "${CFGPORT}" "mongod"
  # start a PBM agent on the mongos node (currently required, but in the future it shouldn't be)
  start_pbm_agent "${NODESDIR}/${SHNAME}" "nors" "${SHPORT}" "mongos"
fi

