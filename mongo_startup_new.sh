#!/usr/bin/env bash

# dynamic
MONGO_USER="dba"
MONGO_PASS="test1234"
MONGO_BACKUP_USER="backupUser"
MONGO_BACKUP_PASS="test1234"
# static or changed with cmd line options
HOST="localhost"
BASEDIR="$(pwd)"
WORKDIR=""
LAYOUT=""
STORAGE_ENGINE="wiredTiger"
MONGOD_EXTRA="--bind_ip 0.0.0.0"
MONGOS_EXTRA="--bind_ip 0.0.0.0"
CONFIG_EXTRA="--bind_ip 0.0.0.0"
RS_ARBITER=0
RS_HIDDEN=0
RS_DELAYED=0
NUM_SETUPS=1
RS_NODES=3
ENCRYPTION="no"
PBMDIR=""
PBM_STORAGE="fs"
AUTH=""
BACKUP_AUTH=""
BACKUP_URI_AUTH=""
BACKUP_URI_SUFFIX=""
TLS=0
TLS_CLIENT=""

if [ -z $1 ]; then
  echo "You need to specify at least one of the options for layout: --rSet, --sCluster or use --help!"
  exit 1
fi

# Check if we have a functional getopt(1)
if ! getopt --test
then
    go_out="$(getopt --options=rsahe:b:o:t:p:n:c:xw: \
        --longoptions=rSet,sCluster,arbiter,hidden,delayed,help,storageEngine:,binDir:,host:,mongodExtra:,mongosExtra:,configExtra:,encrypt:,pbmDir:,auth,ssl,workDir:,numSetups:,rsNodes: \
        --name="$(basename "$0")" -- "$@")"
    test $? -eq 0 || exit 1
    eval set -- $go_out
fi

for arg
do
  case "$arg" in
  -- ) shift; break;;
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
    echo -e "\nThis script can be used to setup replica set or sharded cluster of mongod or psmdb from binary tarball."
    echo -e "By default it should be run from mongodb/psmdb base directory."
    echo -e "Setup is located in the \"nodes\" subdirectory.\n"
    echo -e "Options:"
    echo -e "-r, --rSet\t\t\t run replica set (3 nodes by default)"
    echo -e "-s, --sCluster\t\t\t run sharding cluster (2 replica sets with 3 nodes each by default)"
    echo -e "-a, --arbiter\t\t\t add arbiter node (requires at least 2 normal nodes)"
    echo -e "-n<num>, --numSetups=<num>\t number of setups to create (default: 1)"
    echo -e "-c<num>, --rsNodes=<num>\t\t number of nodes in replica set (default: 3)"
    echo -e "-e<se>, --storageEngine=<se>\t specify storage engine for data nodes (wiredTiger, mmapv1)"
    echo -e "-b<path>, --binDir=<path>\t specify binary directory if running from some other location (this should end with /bin)"
    echo -e "-w<path>, --workDir=<path>\t specify work directory if not current"
    echo -e "-o<name>, --host=<name>\t\t instead of localhost specify some hostname for MongoDB setup"
    echo -e "--mongodExtra=\"...\"\t\t specify extra options to pass to mongod"
    echo -e "--mongosExtra=\"...\"\t\t specify extra options to pass to mongos"
    echo -e "--configExtra=\"...\"\t\t specify extra options to pass to config server"
    echo -e "--tls\t\t\t\t generate tls certificates and start nodes with requiring tls connection"
    echo -e "-t, --encrypt\t\t\t enable data at rest encryption with keyfile (wiredTiger only)"
    echo -e "-p<path>, --pbmDir=<path>\t enables Percona Backup for MongoDB (starts agents from binaries)"
    echo -e "-x, --auth\t\t\t enable authentication"
    echo -e "-h, --help\t\t\t this help"
    echo -e "--hidden\t\t\t add hidden node (requires at least 1 normal node)"
    echo -e "--delayed\t\t\t add delayed node with 600s delay (requires at least 1 normal node)"
    exit 0
    ;;
  -e | --storageEngine )
    shift
    STORAGE_ENGINE="$1"
    shift
    ;;
  --hidden )
    shift
    RS_HIDDEN=1
    ;;
  --delayed )
    shift
    RS_DELAYED=1
    ;;
  --mongodExtra )
    shift
    MONGOD_EXTRA="${MONGOD_EXTRA} $1"
    shift
    ;;
  --mongosExtra )
    shift
    MONGOS_EXTRA="${MONGOS_EXTRA} $1"
    shift
    ;;
  --configExtra )
    shift
    CONFIG_EXTRA="${CONFIG_EXTRA} $1"
    shift
    ;;
  -t | --encrypt )
    shift
    ENCRYPTION="keyfile"
    shift
    ;;
  -b | --binDir )
    shift
    BINDIR="$1"
    shift
    ;;
  -o | --host )
    shift
    HOST="$1"
    shift
    ;;
  -p | --pbmDir )
    shift
    PBMDIR="$1"
    shift
    ;;
  -n | --numSetups )
    shift
    NUM_SETUPS="$1"
    shift
    ;;
  -c | --rsNodes )
    shift
    RS_NODES="$1"
    shift
    ;;
  -x | --auth )
    shift
    AUTH="--username=${MONGO_USER} --password=${MONGO_PASS} --authenticationDatabase=admin"
    BACKUP_AUTH="--username=${MONGO_BACKUP_USER} --password=${MONGO_BACKUP_PASS} --authenticationDatabase=admin"
    BACKUP_DOCKER_AUTH="-e PBM_AGENT_MONGODB_USERNAME=${MONGO_BACKUP_USER} -e PBM_AGENT_MONGODB_PASSWORD=${MONGO_BACKUP_PASS} -e PBM_AGENT_MONGODB-AUTHDB=admin"
    BACKUP_URI_AUTH="${MONGO_BACKUP_USER}:${MONGO_BACKUP_PASS}@"
    BACKUP_URI_SUFFIX="?authSource=admin"
    ;;
  --tls )
    shift
    TLS=1
    ;;
  -w | --workDir )
    shift
    WORKDIR="$1"
    shift
    ;;
  esac
done

if [ "${STORAGE_ENGINE}" != "wiredTiger" -a "${ENCRYPTION}" != "no" ]; then
  echo "ERROR: Data at rest encryption is possible only with wiredTiger storage engine!"
  exit 1
fi
if [ "${ENCRYPTION}" != "no" -a "${ENCRYPTION}" != "keyfile" ]; then
  echo "ERROR: --encrypt parameter can be: no or keyfile!"
  exit 1
fi
TOTAL_SPECIAL_NODES=$((RS_ARBITER + RS_HIDDEN + RS_DELAYED))
MIN_NORMAL_NODES=1

if [ ${RS_ARBITER} = 1 ]; then
  MIN_NORMAL_NODES=2
fi
if [ ${RS_HIDDEN} = 1 ] && [ ${MIN_NORMAL_NODES} -lt 1 ]; then
  MIN_NORMAL_NODES=1
fi
if [ ${RS_DELAYED} = 1 ] && [ ${MIN_NORMAL_NODES} -lt 1 ]; then
  MIN_NORMAL_NODES=1
fi

MIN_TOTAL_NODES=$((MIN_NORMAL_NODES + TOTAL_SPECIAL_NODES))

if [ ${RS_NODES} -lt ${MIN_TOTAL_NODES} ]; then
  echo "ERROR: Not enough nodes for the requested configuration."
  echo "  Arbiter: ${RS_ARBITER}, Hidden: ${RS_HIDDEN}, Delayed: ${RS_DELAYED}"
  echo "  Minimum required nodes: ${MIN_TOTAL_NODES} (${MIN_NORMAL_NODES} normal + ${TOTAL_SPECIAL_NODES} special)"
  echo "  Current nodes: ${RS_NODES}"
  exit 1
fi

if [ -z "${BINDIR}" ]; then
  BINDIR="${BASEDIR}/bin"
fi
if [ -z "${WORKDIR}" ]; then
  WORKDIR="${BASEDIR}/nodes"
fi

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

if [ ! -z "${PBMDIR}" -a ! -x "${PBMDIR}/pbm" ]; then
  echo "${PBMDIR}/pbm doesn't exists or is not executable!"
  exit 1
elif [ ! -z "${PBMDIR}" -a ! -x "${PBMDIR}/pbm-agent" ]; then
  echo "${PBMDIR}/pbm-agent doesn't exists or is not executable!"
  exit 1
fi

if [ -d "${WORKDIR}" ]; then
  echo "${WORKDIR} already exists"
  exit 1
else
  mkdir "${WORKDIR}"
fi

echo "MONGO_USER=\"${MONGO_USER}\"" > ${WORKDIR}/COMMON
echo "MONGO_PASS=\"${MONGO_PASS}\"" >> ${WORKDIR}/COMMON
echo "MONGO_BACKUP_USER=\"${MONGO_BACKUP_USER}\"" >> ${WORKDIR}/COMMON
echo "MONGO_BACKUP_PASS=\"${MONGO_BACKUP_PASS}\"" >> ${WORKDIR}/COMMON
echo "AUTH=\"\"" >> ${WORKDIR}/COMMON
echo "BACKUP_AUTH=\"\"" >> ${WORKDIR}/COMMON
echo "BACKUP_DOCKER_AUTH=\"\"" >> ${WORKDIR}/COMMON
echo "BACKUP_URI_AUTH=\"\"" >> ${WORKDIR}/COMMON

if [ ! -z "${AUTH}" ]; then
  openssl rand -base64 756 > ${WORKDIR}/keyFile
  chmod 400 ${WORKDIR}/keyFile
  MONGOD_EXTRA="${MONGOD_EXTRA} --keyFile ${WORKDIR}/keyFile"
  MONGOS_EXTRA="${MONGOS_EXTRA} --keyFile ${WORKDIR}/keyFile"
  CONFIG_EXTRA="${CONFIG_EXTRA} --keyFile ${WORKDIR}/keyFile"
fi


setup_pbm_agent(){
  local NDIR="$1"
  local RS="$2"
  local NPORT="$3"

  rm -f "${NDIR}/pbm-agent"
  mkdir -p "${NDIR}/pbm-agent"

  if [ ! -z "${PBMDIR}" ]; then
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "source ${WORKDIR}/COMMON" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "echo '=== Starting pbm-agent for mongod on port: ${NPORT} replicaset: ${RS} ==='" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${PBMDIR}/pbm-agent --mongodb-uri=\"mongodb://\${BACKUP_URI_AUTH}${HOST}:${NPORT}/${BACKUP_URI_SUFFIX}\" 1>${NDIR}/pbm-agent/stdout.log 2>${NDIR}/pbm-agent/stderr.log &" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${NDIR}/pbm-agent/start_pbm_agent.sh" >> ${WORKDIR}/start_pbm.sh

    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/stop_pbm_agent.sh
    echo "kill \$(cat ${NDIR}/pbm-agent/pbm-agent.pid)" >> ${NDIR}/pbm-agent/stop_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/stop_pbm_agent.sh

    ln -s ${PBMDIR}/pbm-agent ${NDIR}/pbm-agent/pbm-agent

  fi
}

start_mongod(){
  local NDIR="$1"
  local RS="$2"
  local PORT="$3"
  local SE="$4"
  local EXTRA="$5"
  local NTYPE="$6"
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
      EXTRA="${EXTRA} --enableEncryption --encryptionKeyFile ${NDIR}/mongodb-keyfile --encryptionCipherMode AES256-CBC"
    fi
  fi
  if [ ${TLS} -eq 1 ]; then
    EXTRA="${EXTRA} --tlsMode requireTLS --tlsCertificateKeyFile ${WORKDIR}/certificates/server.pem --tlsCAFile ${WORKDIR}/certificates/ca.crt"
  fi

  echo "#!/usr/bin/env bash" > ${NDIR}/start.sh
  echo "source ${WORKDIR}/COMMON" >> ${NDIR}/start.sh
  echo "echo \"Starting mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/start.sh
  echo "ENABLE_AUTH=\"\"" >> ${NDIR}/start.sh
  echo "if [ ! -z \"\${AUTH}\" ]; then ENABLE_AUTH=\"--auth\"; fi" >> ${NDIR}/start.sh
  if [ "${NTYPE}" == "arbiter" ]; then
      echo "${BINDIR}/mongod --port ${PORT} --storageEngine ${SE} --dbpath ${NDIR}/db --logpath ${NDIR}/mongod.log --fork ${EXTRA} > /dev/null" >> ${NDIR}/start.sh
  else
      echo "${BINDIR}/mongod \${ENABLE_AUTH} --port ${PORT} --storageEngine ${SE} --dbpath ${NDIR}/db --logpath ${NDIR}/mongod.log --fork ${EXTRA} > /dev/null" >> ${NDIR}/start.sh
  fi
  echo "#!/usr/bin/env bash" > ${NDIR}/cl.sh
  echo "source ${WORKDIR}/COMMON" >> ${NDIR}/cl.sh
  if [ "${NTYPE}" == "arbiter" ]; then
      echo "${BINDIR}/mongo ${HOST}:${PORT} \${TLS_CLIENT} \$@" >> ${NDIR}/cl.sh
  else
      echo "${BINDIR}/mongo ${HOST}:${PORT} \${AUTH} \${TLS_CLIENT} \$@" >> ${NDIR}/cl.sh
  fi
  echo "#!/usr/bin/env bash" > ${NDIR}/stop.sh
  echo "source ${WORKDIR}/COMMON" >> ${NDIR}/stop.sh
  echo "echo \"Stopping mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/stop.sh
  if [ "${NTYPE}" == "arbiter" ]; then
      echo "${BINDIR}/mongo localhost:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${TLS_CLIENT}" >> ${NDIR}/stop.sh
  else
      echo "${BINDIR}/mongo localhost:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH} \${TLS_CLIENT}" >> ${NDIR}/stop.sh
  fi
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
  local nodes=()
  local normal_nodes=$((RS_NODES - RS_ARBITER - RS_HIDDEN - RS_DELAYED))
  
  for ((i=1; i<=normal_nodes; i++)); do
    nodes+=("config")
  done
  
  if [ ${RS_HIDDEN} = 1 ]; then
    nodes+=("hidden")
  fi
  
  if [ ${RS_DELAYED} = 1 ]; then
    nodes+=("delayed")
  fi
  
  if [ ${RS_ARBITER} = 1 ] && [ "${RSNAME}" != "config" ]; then
    nodes+=("arbiter")
  fi
  echo -e "\n=== Starting replica set: ${RSNAME} ==="
  for i in "${!nodes[@]}"; do
    node_number=$(($i + 1))
    if [ "${RSNAME}" != "config" ]; then
          start_mongod "${RSDIR}/node${node_number}" "${RSNAME}" "$(($RSBASEPORT + ${i}))" "${STORAGE_ENGINE}" "${EXTRA}" "${nodes[$i]}"
    else
          start_mongod "${RSDIR}/node${node_number}" "${RSNAME}" "$(($RSBASEPORT + ${i}))" "wiredTiger" "${EXTRA}" "${nodes[$i]}"
    fi
  done
  sleep 5
  echo "#!/usr/bin/env bash" > ${RSDIR}/init_rs.sh
  echo "source ${WORKDIR}/COMMON" >> ${RSDIR}/init_rs.sh
  echo "echo \"Initializing replica set: ${RSNAME}\"" >> ${RSDIR}/init_rs.sh
  MEMBERS="["
  local member_id=1
  local normal_nodes=$((RS_NODES - RS_ARBITER - RS_HIDDEN - RS_DELAYED))
  
  for ((i=0; i<normal_nodes; i++)); do
    if [ ${member_id} -gt 1 ]; then
      MEMBERS="${MEMBERS},"
    fi
    MEMBERS="${MEMBERS}{\"_id\":${member_id}, \"host\":\"${HOST}:$(($RSBASEPORT + ${i}))\"}"
    member_id=$((member_id + 1))
  done
  
  if [ ${RS_HIDDEN} = 1 ]; then
    if [ ${member_id} -gt 1 ]; then
      MEMBERS="${MEMBERS},"
    fi
    MEMBERS="${MEMBERS}{\"_id\":${member_id}, \"host\":\"${HOST}:$(($RSBASEPORT + normal_nodes))\", \"priority\":0, \"hidden\":true}"
    member_id=$((member_id + 1))
  fi
  
  if [ ${RS_DELAYED} = 1 ]; then
    if [ ${member_id} -gt 1 ]; then
      MEMBERS="${MEMBERS},"
    fi
    local delayed_port_offset=$((normal_nodes + RS_HIDDEN))
    MEMBERS="${MEMBERS}{\"_id\":${member_id}, \"host\":\"${HOST}:$(($RSBASEPORT + delayed_port_offset))\", \"priority\":0, \"secondaryDelaySecs\":600}"
    member_id=$((member_id + 1))
  fi
  
  if [ ${RS_ARBITER} = 1 ] && [ "${RSNAME}" != "config" ]; then
    if [ ${member_id} -gt 1 ]; then
      MEMBERS="${MEMBERS},"
    fi
    local arbiter_port_offset=$((normal_nodes + RS_HIDDEN + RS_DELAYED))
    MEMBERS="${MEMBERS}{\"_id\":${member_id}, \"host\":\"${HOST}:$(($RSBASEPORT + arbiter_port_offset))\",\"arbiterOnly\":true}"
  fi
  
  MEMBERS="${MEMBERS}]"
  
  local init_port=${RSBASEPORT}
  if [ ${RS_NODES} -gt 1 ]; then
    init_port=$(($RSBASEPORT + 1))
  fi
  
  echo "${BINDIR}/mongo localhost:${init_port} --quiet \${TLS_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", members: ${MEMBERS}})'" >> ${RSDIR}/init_rs.sh
  echo "#!/usr/bin/env bash" > ${RSDIR}/stop_mongodb.sh
  echo "echo \"=== Stopping replica set: ${RSNAME} ===\"" >> ${RSDIR}/stop_mongodb.sh
  for cmd in $(find ${RSDIR} -name stop.sh); do
    echo "${cmd}" >> ${RSDIR}/stop_mongodb.sh
  done
  echo "#!/usr/bin/env bash" > ${RSDIR}/start_mongodb.sh
  echo "echo \"=== Starting replica set: ${RSNAME} ===\"" >> ${RSDIR}/start_mongodb.sh
  for cmd in $(find ${RSDIR} -name start.sh); do
    echo "${cmd}" >> ${RSDIR}/start_mongodb.sh
  done
  echo "#!/usr/bin/env bash" > ${RSDIR}/cl_primary.sh
  echo "source ${WORKDIR}/COMMON" >> ${RSDIR}/cl_primary.sh
  if [ ${RS_NODES} -eq 1 ]; then
    echo "${BINDIR}/mongo ${HOST}:${RSBASEPORT} \${AUTH} \${TLS_CLIENT} \$@" >> ${RSDIR}/cl_primary.sh
  else
    local connection_string="mongodb://"
    for ((i=0; i<RS_NODES; i++)); do
      if [ ${i} -gt 0 ]; then
        connection_string="${connection_string},"
      fi
      connection_string="${connection_string}${HOST}:$(($RSBASEPORT + i))"
    done
    connection_string="${connection_string}/?replicaSet=${RSNAME}"
    echo "${BINDIR}/mongo \"${connection_string}\" \${AUTH} \${TLS_CLIENT} \$@" >> ${RSDIR}/cl_primary.sh
  fi
  chmod +x ${RSDIR}/init_rs.sh
  chmod +x ${RSDIR}/start_mongodb.sh
  chmod +x ${RSDIR}/stop_mongodb.sh
  chmod +x ${RSDIR}/cl_primary.sh
  ${RSDIR}/init_rs.sh

  # for config server this is done via mongos
  if [ ! -z "${AUTH}" -a "${RSNAME}" != "config" ]; then
    sleep 20
    if [ ${RS_NODES} -eq 1 ]; then
      ${BINDIR}/mongo localhost:${RSBASEPORT} --quiet ${TLS_CLIENT} --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] })"
      ${BINDIR}/mongo ${AUTH} ${TLS_CLIENT} localhost:${RSBASEPORT} --quiet --eval "db.getSiblingDB(\"admin\").createRole( { role: \"pbmAnyAction\", privileges: [ { resource: { anyResource: true }, actions: [ \"anyAction\" ] } ], roles: [] } )"
      ${BINDIR}/mongo ${AUTH} ${TLS_CLIENT} localhost:${RSBASEPORT} --quiet --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"readWrite\", collection: \"\" }, { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" }, { db: \"admin\", role: \"pbmAnyAction\" } ] })"
    else
      local PRIMARY=$(${BINDIR}/mongo localhost:${RSBASEPORT} --quiet ${TLS_CLIENT} --eval "db.isMaster().primary"|tail -n1|cut -d':' -f2)
      ${BINDIR}/mongo localhost:${PRIMARY} --quiet ${TLS_CLIENT} --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] })"
      local connection_string="mongodb://"
      for ((i=0; i<RS_NODES; i++)); do
        if [ ${i} -gt 0 ]; then
          connection_string="${connection_string},"
        fi
        connection_string="${connection_string}${HOST}:$(($RSBASEPORT + i))"
      done
      connection_string="${connection_string}/?replicaSet=${RSNAME}"
      ${BINDIR}/mongo ${AUTH} ${TLS_CLIENT} "${connection_string}" --quiet --eval "db.getSiblingDB(\"admin\").createRole( { role: \"pbmAnyAction\", privileges: [ { resource: { anyResource: true }, actions: [ \"anyAction\" ] } ], roles: [] } )"
      ${BINDIR}/mongo ${AUTH} ${TLS_CLIENT} "${connection_string}" --quiet --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"readWrite\", collection: \"\" }, { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" }, { db: \"admin\", role: \"pbmAnyAction\" } ] })"
    fi
    sed -i "/^AUTH=/c\AUTH=\"--username=\${MONGO_USER} --password=\${MONGO_PASS} --authenticationDatabase=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_AUTH=/c\BACKUP_AUTH=\"--username=\${MONGO_BACKUP_USER} --password=\${MONGO_BACKUP_PASS} --authenticationDatabase=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_DOCKER_AUTH=/c\BACKUP_DOCKER_AUTH=\"-e PBM_AGENT_MONGODB_USERNAME=\${MONGO_BACKUP_USER} -e PBM_AGENT_MONGODB_PASSWORD=\${MONGO_BACKUP_PASS} -e PBM_AGENT_MONGODB-AUTHDB=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_URI_AUTH=/c\BACKUP_URI_AUTH=\"\${MONGO_BACKUP_USER}:\${MONGO_BACKUP_PASS}@\"" ${WORKDIR}/COMMON
  fi
  # for config server replica set this is done in another place after cluster user is added
  if [ ! -z "${PBMDIR}" -a "${RSNAME}" != "config" ]; then
    sleep 5
    for ((i=1; i<=RS_NODES; i++)); do
      local normal_nodes=$((RS_NODES - RS_ARBITER - RS_HIDDEN - RS_DELAYED))
      local is_arbiter=0
      if [ ${RS_ARBITER} = 1 ] && [ ${i} -gt $((normal_nodes + RS_HIDDEN + RS_DELAYED)) ]; then
        is_arbiter=1
      fi
      if [ ${is_arbiter} = 0 ]; then
        setup_pbm_agent "${RSDIR}/node${i}" "${RSNAME}" "$(($RSBASEPORT + ${i} - 1))"
      fi
    done
  fi
}

set_pbm_store(){
  if [ ! -z "${PBMDIR}" ]; then
    echo "=== Setting PBM store config... ==="
    echo -e "Please run nodes/pbm_store_set.sh manually after editing nodes/storage-config.yaml\n"
    echo "#!/usr/bin/env bash" > ${WORKDIR}/pbm_store_set.sh
    chmod +x ${WORKDIR}/pbm_store_set.sh
    if [ "${LAYOUT}" == "rs" ]; then
      for ((setup=1; setup<=NUM_SETUPS; setup++)); do
        if [ ${NUM_SETUPS} -gt 1 ]; then
          RSNAME="rs${setup}"
          RSPORT=$((27017 + (setup-1) * 100))
        else
          RSNAME="rs1"
          RSPORT=27017
        fi
        local BACKUP_URI_SUFFIX_REPLICA=""
        if [ -z "${BACKUP_URI_SUFFIX}" ]; then BACKUP_URI_SUFFIX_REPLICA="?replicaSet=${RSNAME}"; else BACKUP_URI_SUFFIX_REPLICA="${BACKUP_URI_SUFFIX}&replicaSet=${RSNAME}"; fi
        local URI_HOSTS=""
        for ((i=0; i<RS_NODES; i++)); do
          if [ ${i} -gt 0 ]; then
            URI_HOSTS="${URI_HOSTS},"
          fi
          URI_HOSTS="${URI_HOSTS}${HOST}:$((RSPORT + i))"
        done
        echo "${WORKDIR}/pbm config --file=${WORKDIR}/storage-config.yaml --mongodb-uri='mongodb://${BACKUP_URI_AUTH}${URI_HOSTS}/${BACKUP_URI_SUFFIX_REPLICA}'" >> ${WORKDIR}/pbm_store_set.sh
      done
    elif [ "${LAYOUT}" == "sh" ]; then
      for ((setup=1; setup<=NUM_SETUPS; setup++)); do
        if [ ${NUM_SETUPS} -gt 1 ]; then
          SHPORT=$((27017 + (setup-1) * 1000))
        else
          SHPORT=27017
        fi
        echo "${WORKDIR}/pbm config --file=${WORKDIR}/storage-config.yaml --mongodb-uri='mongodb://${BACKUP_URI_AUTH}${HOST}:${SHPORT}/${BACKUP_URI_SUFFIX}'" >> ${WORKDIR}/pbm_store_set.sh
      done
    fi
  fi
}

if [ ${TLS} -eq 1 ]; then
  mkdir -p "${WORKDIR}/certificates"
  pushd "${WORKDIR}/certificates"
  echo -e "\n=== Generating TLS certificates in ${WORKDIR}/certificates ==="
  openssl req -nodes -x509 -newkey rsa:4096 -keyout ca.key -out ca.crt -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=root/CN=${HOST}/emailAddress=test@percona.com"
  openssl req -nodes -newkey rsa:4096 -keyout server.key -out server.csr -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=server/CN=${HOST}/emailAddress=test@percona.com"
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out server.crt
  cat server.key server.crt > server.pem
  openssl req -nodes -newkey rsa:4096 -keyout client.key -out client.csr -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=client/CN=${HOST}/emailAddress=test@percona.com"
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -set_serial 02 -out client.crt
  cat client.key client.crt > client.pem
  popd
  TLS_CLIENT="--tls --tlsCAFile ${WORKDIR}/certificates/ca.crt --tlsCertificateKeyFile ${WORKDIR}/certificates/client.pem"
  echo "TLS_CLIENT=\"${TLS_CLIENT}\"" >> ${WORKDIR}/COMMON
fi

# Prepare if running with PBM
if [ ! -z "${PBMDIR}" ]; then
  mkdir -p "${WORKDIR}/backup"
  # create symlinks to PBM binaries
  ln -s ${PBMDIR}/pbm ${WORKDIR}/pbm
  ln -s ${PBMDIR}/pbm-agent ${WORKDIR}/pbm-agent

  echo "#!/usr/bin/env bash" > ${WORKDIR}/start_pbm.sh
  chmod +x ${WORKDIR}/start_pbm.sh

  echo "#!/usr/bin/env bash" > ${WORKDIR}/stop_pbm.sh
  echo "killall pbm pbm-agent" >> ${WORKDIR}/stop_pbm.sh
  chmod +x ${WORKDIR}/stop_pbm.sh
fi
if [ ! -z "${PBMDIR}" ]; then
  echo "storage:" >> ${WORKDIR}/storage-config.yaml
  echo "  type: filesystem" >> ${WORKDIR}/storage-config.yaml
  echo "  filesystem:" >> ${WORKDIR}/storage-config.yaml
  echo "    path: ${WORKDIR}/backup" >> ${WORKDIR}/storage-config.yaml
fi

# Run different configurations
if [ "${LAYOUT}" == "rs" ]; then
  for ((setup=1; setup<=NUM_SETUPS; setup++)); do
    if [ ${NUM_SETUPS} -gt 1 ]; then
      RSNAME="rs${setup}"
      RSDIR="${WORKDIR}/rs${setup}"
      RSPORT=$((27017 + (setup-1) * 100))
    else
      RSNAME="rs1"
      RSDIR="${WORKDIR}"
      RSPORT=27017
    fi
    start_replicaset "${RSDIR}" "${RSNAME}" "${RSPORT}" "${MONGOD_EXTRA}"
  done
  if [ ! -z "${PBMDIR}" ]; then
    set_pbm_store
    ${WORKDIR}/start_pbm.sh
  fi
fi

if [ "${LAYOUT}" == "sh" ]; then
  for ((setup=1; setup<=NUM_SETUPS; setup++)); do
    if [ ${NUM_SETUPS} -gt 1 ]; then
      SHPORT=$((27017 + (setup-1) * 1000))
      CFGPORT=$((27027 + (setup-1) * 1000))
      RS1PORT=$((27018 + (setup-1) * 1000))
      RS2PORT=$((28018 + (setup-1) * 1000))
      SHNAME="sh${setup}"
      RS1NAME="rs${setup}_1"
      RS2NAME="rs${setup}_2"
      CFGRSNAME="config${setup}"
      SETUPDIR="${WORKDIR}/sh${setup}"
    else
      SHPORT=27017
      CFGPORT=27027
      RS1PORT=27018
      RS2PORT=28018
      SHNAME="sh1"
      RS1NAME="rs1"
      RS2NAME="rs2"
      CFGRSNAME="config"
      SETUPDIR="${WORKDIR}"
    fi
    mkdir -p "${SETUPDIR}/${RS1NAME}"
    mkdir -p "${SETUPDIR}/${RS2NAME}"
    mkdir -p "${SETUPDIR}/${CFGRSNAME}"
    mkdir -p "${SETUPDIR}/${SHNAME}"

    if [ ${TLS} -eq 1 ]; then
      MONGOS_EXTRA="${MONGOS_EXTRA} --sslMode requireTLS --sslPEMKeyFile ${WORKDIR}/certificates/server.pem --sslCAFile ${WORKDIR}/certificates/ca.crt"
    fi

    echo -e "\n=== Configuring sharding cluster: ${SHNAME} ==="
    start_replicaset "${SETUPDIR}/${CFGRSNAME}" "${CFGRSNAME}" "${CFGPORT}" "--configsvr ${CONFIG_EXTRA}"

    start_replicaset "${SETUPDIR}/${RS1NAME}" "${RS1NAME}" "${RS1PORT}" "--shardsvr ${MONGOD_EXTRA}"
    start_replicaset "${SETUPDIR}/${RS2NAME}" "${RS2NAME}" "${RS2PORT}" "--shardsvr ${MONGOD_EXTRA}"

    echo "#!/usr/bin/env bash" > ${SETUPDIR}/${SHNAME}/start_mongos.sh
    echo "echo \"=== Starting sharding server: ${SHNAME} on port ${SHPORT} ===\"" >> ${SETUPDIR}/${SHNAME}/start_mongos.sh
    if [ ${RS_NODES} -eq 1 ]; then
      configdb_string="${CFGRSNAME}/${HOST}:${CFGPORT}"
    else
      configdb_string="${CFGRSNAME}/"
      for ((i=0; i<RS_NODES; i++)); do
        if [ ${i} -gt 0 ]; then
          configdb_string="${configdb_string},"
        fi
        configdb_string="${configdb_string}${HOST}:$(($CFGPORT + i))"
      done
    fi
    echo "${BINDIR}/mongos --port ${SHPORT} --configdb ${configdb_string} --logpath ${SETUPDIR}/${SHNAME}/mongos.log --fork "$MONGOS_EXTRA" >/dev/null" >> ${SETUPDIR}/${SHNAME}/start_mongos.sh
    echo "#!/usr/bin/env bash" > ${SETUPDIR}/${SHNAME}/cl_mongos.sh
    echo "source ${WORKDIR}/COMMON" >> ${SETUPDIR}/${SHNAME}/cl_mongos.sh
    echo "${BINDIR}/mongo ${HOST}:${SHPORT} \${AUTH} \${TLS_CLIENT} \$@" >> ${SETUPDIR}/${SHNAME}/cl_mongos.sh
    if [ ${NUM_SETUPS} -eq 1 ]; then
      ln -s ${SETUPDIR}/${SHNAME}/cl_mongos.sh ${WORKDIR}/cl_mongos.sh
    fi
    echo "echo \"=== Stopping sharding cluster: ${SHNAME} ===\"" >> ${WORKDIR}/stop_mongodb.sh
    echo "${SETUPDIR}/${SHNAME}/stop_mongos.sh" >> ${WORKDIR}/stop_mongodb.sh
    echo "${SETUPDIR}/${RS1NAME}/stop_mongodb.sh" >> ${WORKDIR}/stop_mongodb.sh
    echo "${SETUPDIR}/${RS2NAME}/stop_mongodb.sh" >> ${WORKDIR}/stop_mongodb.sh
    echo "${SETUPDIR}/${CFGRSNAME}/stop_mongodb.sh" >> ${WORKDIR}/stop_mongodb.sh
    echo "#!/usr/bin/env bash" > ${SETUPDIR}/${SHNAME}/stop_mongos.sh
    echo "source ${WORKDIR}/COMMON" >> ${SETUPDIR}/${SHNAME}/stop_mongos.sh
    echo "echo \"Stopping mongos on port: ${SHPORT}\"" >> ${SETUPDIR}/${SHNAME}/stop_mongos.sh
    echo "${BINDIR}/mongo localhost:${SHPORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH} \${TLS_CLIENT}" >> ${SETUPDIR}/${SHNAME}/stop_mongos.sh
    echo "#!/usr/bin/env bash" > ${SETUPDIR}/start_mongodb.sh
    echo "echo \"Starting sharding cluster on port: ${SHPORT}\"" >> ${SETUPDIR}/start_mongodb.sh
    echo "${SETUPDIR}/${CFGRSNAME}/start_mongodb.sh" >> ${SETUPDIR}/start_mongodb.sh
    echo "${SETUPDIR}/${RS1NAME}/start_mongodb.sh" >> ${SETUPDIR}/start_mongodb.sh
    echo "${SETUPDIR}/${RS2NAME}/start_mongodb.sh" >> ${SETUPDIR}/start_mongodb.sh
    echo "${SETUPDIR}/${SHNAME}/start_mongos.sh" >> ${SETUPDIR}/start_mongodb.sh
    chmod +x ${SETUPDIR}/${SHNAME}/start_mongos.sh
    chmod +x ${SETUPDIR}/${SHNAME}/stop_mongos.sh
    chmod +x ${SETUPDIR}/${SHNAME}/cl_mongos.sh
    chmod +x ${SETUPDIR}/start_mongodb.sh
    if [ ${NUM_SETUPS} -eq 1 ]; then
      chmod +x ${WORKDIR}/start_mongodb.sh
      chmod +x ${WORKDIR}/stop_mongodb.sh
    else
      chmod +x ${WORKDIR}/stop_mongodb.sh
    fi
    # start mongos
    ${SETUPDIR}/${SHNAME}/start_mongos.sh
    if [ ! -z "${AUTH}" ]; then
      ${BINDIR}/mongo localhost:${SHPORT}/admin --quiet ${TLS_CLIENT} --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\", \"userAdminAnyDatabase\", \"clusterAdmin\" ] });"
      ${BINDIR}/mongo ${AUTH} ${TLS_CLIENT} localhost:${SHPORT}/admin --quiet --eval "db.getSiblingDB(\"admin\").createRole( { role: \"pbmAnyAction\", privileges: [ { resource: { anyResource: true }, actions: [ \"anyAction\" ] } ], roles: [] } )"
      ${BINDIR}/mongo ${AUTH} ${TLS_CLIENT} localhost:${SHPORT}/admin --quiet --eval "db.createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"readWrite\", collection: \"\" }, { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" }, { db: \"admin\", role: \"pbmAnyAction\" } ] });"
    fi
    echo "Adding shards to the cluster..."
    sleep 20
    ${BINDIR}/mongo ${HOST}:${SHPORT} --quiet --eval "sh.addShard(\"${RS1NAME}/${HOST}:${RS1PORT}\")" ${AUTH} ${TLS_CLIENT}
    ${BINDIR}/mongo ${HOST}:${SHPORT} --quiet --eval "sh.addShard(\"${RS2NAME}/${HOST}:${RS2PORT}\")" ${AUTH} ${TLS_CLIENT}
    echo -e "\n>>> Enable sharding on specific database with: sh.enableSharding(\"<database>\") <<<"
    echo -e ">>> Shard a collection with: sh.shardCollection(\"<database>.<collection>\", { <key> : <direction> } ) <<<\n"

    if [ ! -z "${PBMDIR}" ]; then
      for ((i=1; i<=RS_NODES; i++)); do
        if [ ${RS_ARBITER} != 1 -o ${i} -lt ${RS_NODES} ]; then
          setup_pbm_agent "${SETUPDIR}/${CFGRSNAME}/node${i}" "${CFGRSNAME}" "$(($CFGPORT + ${i} - 1))"
        fi
      done
    fi
  done
  
  if [ ! -z "${PBMDIR}" ]; then
    set_pbm_store
    ${WORKDIR}/start_pbm.sh
  fi
fi
