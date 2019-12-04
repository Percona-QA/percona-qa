#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

# dynamic
MONGO_USER="dba"
MONGO_PASS="test1234"
MONGO_BACKUP_USER="backupUser"
MONGO_BACKUP_PASS="test1234"
VAULT_SERVER="127.0.0.1"
VAULT_PORT="8200"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-${WORKSPACE}/mongodb-test-vault-token}"
# this is only start of vault secret, additional part is appended per node
VAULT_SECRET="secret_v2/data/psmdb-test"
VAULT_SERVER_CA_FILE="${VAULT_SERVER_CA_FILE:-${WORKSPACE}/test.cer}"
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
CIPHER_MODE="AES256-CBC"
ENCRYPTION="no"
PBMDIR=""
PBM_DOCKER_IMAGE=""
PBM_STORAGE="minio"
AUTH=""
BACKUP_AUTH=""
BACKUP_DOCKER_AUTH=""
BACKUP_URI_AUTH=""
BACKUP_URI_SUFFIX=""
SSL=0
SSL_CLIENT=""

if [ -z $1 ]; then
  echo "You need to specify at least one of the options for layout: --single, --rSet, --sCluster or use --help!"
  exit 1
fi

# Check if we have a functional getopt(1)
if ! getopt --test
then
    go_out="$(getopt --options=mrsahe:b:o:t:c:p:d:xw: \
        --longoptions=single,rSet,sCluster,arbiter,hidden,delayed,help,storageEngine:,binDir:,host:,mongodExtra:,mongosExtra:,configExtra:,encrypt:,cipherMode:,pbmDir:,pbmDocker:,auth,ssl,workDir:,pbmStorage: \
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
    echo -e "-w<path>, --workDir=<path>\t specify work directory if not current"
    echo -e "-o<name>, --host=<name>\t\t instead of localhost specify some hostname for MongoDB setup"
    echo -e "--mongodExtra=\"...\"\t\t specify extra options to pass to mongod"
    echo -e "--mongosExtra=\"...\"\t\t specify extra options to pass to mongos"
    echo -e "--configExtra=\"...\"\t\t specify extra options to pass to config server"
    echo -e "--ssl\t\t\t\t generate ssl certificates and start nodes with requiring ssl connection"
    echo -e "-t, --encrypt\t\t\t enable data at rest encryption (wiredTiger only)"
    echo -e "-c<mode>, --cipherMode=<mode>\t specify cipher mode for encryption (AES256-CBC or AES256-GCM)"
    echo -e "-p<path>, --pbmDir=<path>\t enables Percona Backup for MongoDB (starts agents from binaries)"
    echo -e "--pbmStorage=fs|minio|all\t which storage will be configured for PBM"
    echo -e "-d<image>, --pbmDocker=<image>\t starts Percona Backup for MongoDB agents from docker image"
    echo -e "-x, --auth\t\t\t enable authentication"
    echo -e "-h, --help\t\t\t this help"
    echo -e "--hidden\t\t\t enable hidden node for replica"
    echo -e "--delayed\t\t\t enable delayed node for replica"
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
    ENCRYPTION="$1"
    shift
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
  -d | --pbmDocker )
    shift
    PBM_DOCKER_IMAGE="$1"
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
  --ssl )
    shift
    SSL=1
    ;;
  -w | --workDir )
    shift
    WORKDIR="$1"
    shift
    ;;
  --pbmStorage )
    shift
    PBM_STORAGE="$1"
    shift
    ;;
  esac
done

if [ "${STORAGE_ENGINE}" != "wiredTiger" -a "${ENCRYPTION}" != "no" ]; then
  echo "ERROR: Data at rest encryption is possible only with wiredTiger storage engine!"
  exit 1
fi
if [ "${ENCRYPTION}" != "no" -a "${ENCRYPTION}" != "keyfile" -a "${ENCRYPTION}" != "vault" ]; then
  echo "ERROR: --encrypt parameter can be: no, keyfile or vault!"
  exit 1
fi
if [ ! -z "${PBMDIR}" -a ! -z "${PBM_DOCKER_IMAGE}" ]; then
  echo "ERROR: Cannot specify --pbmDir and --pbmDocker at the same time!"
  exit 1
fi
if [ ! -z "${PBM_DOCKER_IMAGE}" -a "${HOST}" == "localhost" ]; then
  echo "WARNING: When using --pbmDocker option it is recommended to set --host to something different than localhost"
fi
if [ ${RS_DELAYED} = 1 ] && [ ${RS_HIDDEN} = 1 ]; then
  echo "ERROR: Cannot use hidden and delayed nodes together."
  exit 1
fi
if [ ${RS_ARBITER} = 1 ] && [ ${RS_HIDDEN} = 1 ]; then
  echo "ERROR: Cannot use arbiter and hidden nodes together."
  exit 1
fi
if [ ${RS_ARBITER} = 1 ] && [ ${RS_DELAYED} = 1 ]; then
  echo "ERROR: Cannot use arbiter and delayed nodes together."
  exit 1
fi
if [ "${PBM_STORAGE}" != "fs" -a "${PBM_STORAGE}" != "minio" -a "${PBM_STORAGE}" != "all" ]; then
  echo "ERROR: --pbmStorage parameter can be: fs, minio or all!"
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

VERSION_FULL=$(${BINDIR}/mongod --version|head -n1|sed 's/db version v//')
VERSION_MAJOR=$(echo "${VERSION_FULL}"|grep -o '^.\..')

setup_pbm_agent(){
  local NDIR="$1"
  local RS="$2"
  local NPORT="$3"

  mkdir -p "${NDIR}/pbm-agent"

  if [ ! -z "${PBMDIR}" ]; then
    # Create startup script for the agent on the node
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "source ${WORKDIR}/COMMON" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "echo '=== Starting pbm-agent for mongod on port: ${NPORT} replicaset: ${RS} ==='" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${PBMDIR}/pbm-agent --mongodb-uri=\"mongodb://\${BACKUP_URI_AUTH}${HOST}:${NPORT}/${BACKUP_URI_SUFFIX}\" 1>${NDIR}/pbm-agent/stdout.log 2>${NDIR}/pbm-agent/stderr.log &" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${NDIR}/pbm-agent/start_pbm_agent.sh" >> ${WORKDIR}/start_pbm.sh

    # Create stop script for the agent on the node
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/stop_pbm_agent.sh
    echo "kill \$(cat ${NDIR}/pbm-agent/pbm-agent.pid)" >> ${NDIR}/pbm-agent/stop_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/stop_pbm_agent.sh

    # create a symlink for pbm-agent binary
    ln -s ${PBMDIR}/pbm-agent ${NDIR}/pbm-agent/pbm-agent

  elif [ ! -z "${PBM_DOCKER_IMAGE}" ]; then
    local CONTAINER_NAME="pbm-agent-${RS}-${NPORT}"
    mkdir -p ${WORKDIR}/backup/pbm-agent-${RS}-${NPORT}

    # Create startup script for the agent from docker image
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/create_pbm_agent.sh
    echo "source ${WORKDIR}/COMMON" >> ${NDIR}/pbm-agent/create_pbm_agent.sh
    echo "echo \"=== Starting pbm-agent for mongod on port: ${NPORT} replicaset: ${RS} from docker image ===\"" >> ${NDIR}/pbm-agent/create_pbm_agent.sh
    echo "docker run -d --restart=always --user=$(id -u) --name=${CONTAINER_NAME} -e PBM_AGENT_SERVER_ADDRESS=${HOST}:10000 -e PBM_AGENT_BACKUP_DIR=/data -e PBM_AGENT_MONGODB_HOST=${HOST} -e PBM_AGENT_MONGODB_PORT=${NPORT} ${BACKUP_DOCKER_AUTH} -e PBM_AGENT_STORAGE_CONFIG=/logdir/storage-config.yaml -e PBM_AGENT_MONGODB_REPLICASET=${RS} -e PBM_AGENT_LOG_FILE=/logdir/pbm-agent.log -v ${WORKDIR}/backup/${CONTAINER_NAME}:/data -v ${NDIR}/pbm-agent:/logdir ${PBM_DOCKER_IMAGE} pbm-agent" >> ${NDIR}/pbm-agent/create_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/create_pbm_agent.sh
    ${NDIR}/pbm-agent/create_pbm_agent.sh

    # Create start/stop script for the agent from docker image
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "docker start ${CONTAINER_NAME}" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/stop_pbm_agent.sh
    echo "docker stop ${CONTAINER_NAME}" >> ${NDIR}/pbm-agent/stop_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/stop_pbm_agent.sh
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/destroy_pbm_agent.sh
    echo "docker stop ${CONTAINER_NAME}" >> ${NDIR}/pbm-agent/destroy_pbm_agent.sh
    echo "docker rm ${CONTAINER_NAME}" >> ${NDIR}/pbm-agent/destroy_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/destroy_pbm_agent.sh

    echo "${NDIR}/pbm-agent/start_pbm_agent.sh" >> ${WORKDIR}/start_pbm.sh
    echo "${NDIR}/pbm-agent/stop_pbm_agent.sh" >> ${WORKDIR}/stop_pbm.sh
    echo "${NDIR}/pbm-agent/destroy_pbm_agent.sh" >> ${WORKDIR}/destroy_pbm.sh
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
      EXTRA="${EXTRA} --enableEncryption --encryptionKeyFile ${NDIR}/mongodb-keyfile --encryptionCipherMode ${CIPHER_MODE}"
    elif [ "${ENCRYPTION}" = "vault" ]; then
      EXTRA="${EXTRA} --enableEncryption --encryptionCipherMode ${CIPHER_MODE} --vaultServerName ${VAULT_SERVER} --vaultPort ${VAULT_PORT} --vaultTokenFile ${VAULT_TOKEN_FILE} --vaultSecret ${VAULT_SECRET}/${RS}-${PORT} --vaultServerCAFile ${VAULT_SERVER_CA_FILE}"
    fi
  elif [ "${SE}" == "rocksdb" ]; then
    EXTRA="${EXTRA} --rocksdbCacheSizeGB 1"
    if [ "${VERSION_MAJOR}" = "3.6" ]; then
      EXTRA="${EXTRA} --useDeprecatedMongoRocks"
    fi
  fi
  if [ ${SSL} -eq 1 ]; then
    EXTRA="${EXTRA} --sslMode requireSSL --sslPEMKeyFile ${WORKDIR}/certificates/server.pem --sslCAFile ${WORKDIR}/certificates/ca.crt"
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
      echo "${BINDIR}/mongo ${HOST}:${PORT} \${SSL_CLIENT} \$@" >> ${NDIR}/cl.sh
  else
      echo "${BINDIR}/mongo ${HOST}:${PORT} \${AUTH} \${SSL_CLIENT} \$@" >> ${NDIR}/cl.sh
  fi
  echo "#!/usr/bin/env bash" > ${NDIR}/stop.sh
  echo "source ${WORKDIR}/COMMON" >> ${NDIR}/stop.sh
  echo "echo \"Stopping mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/stop.sh
  if [ "${NTYPE}" == "arbiter" ]; then
      echo "${BINDIR}/mongo localhost:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${SSL_CLIENT}" >> ${NDIR}/stop.sh
  else
      echo "${BINDIR}/mongo localhost:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH} \${SSL_CLIENT}" >> ${NDIR}/stop.sh
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
  if [ ${RS_ARBITER} = 1 ] && [ "${RSNAME}" != "config" ]; then
    nodes=(config config arbiter)
  else
    nodes=(config config config)
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
  if [ ${RS_ARBITER} = 0 ] && [ ${RS_DELAYED} = 0 ] && [ ${RS_HIDDEN} = 0 ]; then
    MEMBERS="[{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"${HOST}:$(($RSBASEPORT + 2))\"}]"
    if [ "${STORAGE_ENGINE}" == "inMemory" -a "${RSNAME}" != "config" ]; then
      echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", writeConcernMajorityJournalDefault: false, members: ${MEMBERS}})'" >> ${RSDIR}/init_rs.sh
    else
      echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", members: ${MEMBERS}})'" >> ${RSDIR}/init_rs.sh
    fi
  else
    if [ ${RS_DELAYED} = 1 ] || [ ${RS_HIDDEN} = 1 ]; then
	    MEMBERS="[{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"${HOST}:$(($RSBASEPORT + 2))\", \"priority\":0, \"hidden\":true}]"
      echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", members: ${MEMBERS}})'" >> ${RSDIR}/init_rs.sh
    else
      if [ "${RSNAME}" == "config" ]; then
        MEMBERS="[{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"${HOST}:$(($RSBASEPORT + 2))\"}]"
      else
        MEMBERS="[{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"${HOST}:$(($RSBASEPORT + 2))\",\"arbiterOnly\":true}]"
      fi
      echo "${BINDIR}/mongo localhost:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", members: ${MEMBERS}})'" >> ${RSDIR}/init_rs.sh
    fi
  fi
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
  if [ "${VERSION_MAJOR}" = "3.2" ]; then
    echo "PRIMARY=\$(${BINDIR}/mongo ${HOST}:$(($RSBASEPORT + 1)) --quiet --eval 'db.runCommand(\"ismaster\").primary' | tail -n1) \${AUTH} \${SSL_CLIENT}" >> ${RSDIR}/cl_primary.sh
    echo "${BINDIR}/mongo \${PRIMARY} \${AUTH} \${SSL_CLIENT} \$@" >> ${RSDIR}/cl_primary.sh
  else
    echo "${BINDIR}/mongo \"mongodb://${HOST}:${RSBASEPORT},${HOST}:$(($RSBASEPORT + 1)),${HOST}:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}\" \${AUTH} \${SSL_CLIENT} \$@" >> ${RSDIR}/cl_primary.sh
  fi
  chmod +x ${RSDIR}/init_rs.sh
  chmod +x ${RSDIR}/start_mongodb.sh
  chmod +x ${RSDIR}/stop_mongodb.sh
  chmod +x ${RSDIR}/cl_primary.sh
  ${RSDIR}/init_rs.sh

  # for config server this is done via mongos
  if [ ! -z "${AUTH}" -a "${RSNAME}" != "config" ]; then
    sleep 20
    local PRIMARY=$(${BINDIR}/mongo localhost:${RSBASEPORT} --quiet ${SSL_CLIENT} --eval "db.isMaster().primary"|tail -n1|cut -d':' -f2)
    ${BINDIR}/mongo localhost:${PRIMARY} --quiet ${SSL_CLIENT} --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] })"
    ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} "mongodb://${HOST}:${RSBASEPORT},${HOST}:$(($RSBASEPORT + 1)),${HOST}:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}" --quiet --eval "db.getSiblingDB(\"admin\").createRole( { role: \"pbmAnyAction\", privileges: [ { resource: { anyResource: true }, actions: [ \"anyAction\" ] } ], roles: [] } )"
    ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} "mongodb://${HOST}:${RSBASEPORT},${HOST}:$(($RSBASEPORT + 1)),${HOST}:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}" --quiet --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"readWrite\", collection: \"\" }, { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" }, { db: \"admin\", role: \"pbmAnyAction\" } ] })"
    sed -i "/^AUTH=/c\AUTH=\"--username=\${MONGO_USER} --password=\${MONGO_PASS} --authenticationDatabase=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_AUTH=/c\BACKUP_AUTH=\"--username=\${MONGO_BACKUP_USER} --password=\${MONGO_BACKUP_PASS} --authenticationDatabase=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_DOCKER_AUTH=/c\BACKUP_DOCKER_AUTH=\"-e PBM_AGENT_MONGODB_USERNAME=\${MONGO_BACKUP_USER} -e PBM_AGENT_MONGODB_PASSWORD=\${MONGO_BACKUP_PASS} -e PBM_AGENT_MONGODB-AUTHDB=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_URI_AUTH=/c\BACKUP_URI_AUTH=\"\${MONGO_BACKUP_USER}:\${MONGO_BACKUP_PASS}@\"" ${WORKDIR}/COMMON
  fi
  if [ ${RS_DELAYED} = 1 ]; then
     ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} "mongodb://localhost:$(($RSBASEPORT + 1))/?replicaSet=${RSNAME}" --quiet --eval "cfg = rs.conf(); cfg.members[2].slaveDelay = 600; rs.reconfig(cfg);"
  fi
  # start PBM agents for replica set nodes
  # for config server replica set this is done in another place after cluster user is added
  if [ ! -z "${PBMDIR}${PBM_DOCKER_IMAGE}" -a "${RSNAME}" != "config" ]; then
    sleep 5
    for i in 1 2 3; do
      if [ ${RS_ARBITER} != 1 -o ${i} -lt 3 ]; then
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
    if [ "${LAYOUT}" == "single" ]; then
      echo "${WORKDIR}/pbm config --file=${WORKDIR}/storage-config.yaml --mongodb-uri='mongodb://${BACKUP_URI_AUTH}${HOST}:27017/${BACKUP_URI_SUFFIX}'" >> ${WORKDIR}/pbm_store_set.sh
    elif [ "${LAYOUT}" == "rs" ]; then
      local BACKUP_URI_SUFFIX_REPLICA=""
      if [ -z "${BACKUP_URI_SUFFIX}" ]; then BACKUP_URI_SUFFIX_REPLICA="?replicaSet=rs1"; else BACKUP_URI_SUFFIX_REPLICA="${BACKUP_URI_SUFFIX}&replicaSet=rs1"; fi
      echo "${WORKDIR}/pbm config --file=${WORKDIR}/storage-config.yaml --mongodb-uri='mongodb://${BACKUP_URI_AUTH}${HOST}:27017,${HOST}:27018,${HOST}:27019/${BACKUP_URI_SUFFIX_REPLICA}'" >> ${WORKDIR}/pbm_store_set.sh
    elif [ "${LAYOUT}" == "sh" ]; then
      echo "${WORKDIR}/pbm config --file=${WORKDIR}/storage-config.yaml --mongodb-uri='mongodb://${BACKUP_URI_AUTH}${HOST}:27017/${BACKUP_URI_SUFFIX}'" >> ${WORKDIR}/pbm_store_set.sh
    fi
  fi
}

# General prepare
if [ ${SSL} -eq 1 ]; then
  mkdir -p "${WORKDIR}/certificates"
  pushd "${WORKDIR}/certificates"
  echo -e "\n=== Generating SSL certificates in ${WORKDIR}/certificates ==="
  # Generate self signed root CA cert
  openssl req -nodes -x509 -newkey rsa:4096 -keyout ca.key -out ca.crt -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=root/CN=${HOST}/emailAddress=test@percona.com"
  # Generate server cert to be signed
  openssl req -nodes -newkey rsa:4096 -keyout server.key -out server.csr -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=server/CN=${HOST}/emailAddress=test@percona.com"
  # Sign server sert
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out server.crt
  # Create server PEM file
  cat server.key server.crt > server.pem
  # Generate client cert to be signed
  openssl req -nodes -newkey rsa:4096 -keyout client.key -out client.csr -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=client/CN=${HOST}/emailAddress=test@percona.com"
  # Sign the client cert
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -set_serial 02 -out client.crt
  # Create client PEM file
  cat client.key client.crt > client.pem
  popd
  SSL_CLIENT="--ssl --sslCAFile ${WORKDIR}/certificates/ca.crt --sslPEMKeyFile ${WORKDIR}/certificates/client.pem"
  echo "SSL_CLIENT=\"${SSL_CLIENT}\"" >> ${WORKDIR}/COMMON
fi

# Prepare if running with PBM
if [ ! -z "${PBMDIR}" ]; then
  mkdir -p "${WORKDIR}/backup"
  # create symlinks to PBM binaries
  ln -s ${PBMDIR}/pbm ${WORKDIR}/pbm
  ln -s ${PBMDIR}/pbm-agent ${WORKDIR}/pbm-agent

  # create startup/stop scripts for the whole PBM setup
  echo "#!/usr/bin/env bash" > ${WORKDIR}/start_pbm.sh
  chmod +x ${WORKDIR}/start_pbm.sh

  echo "#!/usr/bin/env bash" > ${WORKDIR}/stop_pbm.sh
  echo "killall pbm pbm-agent" >> ${WORKDIR}/stop_pbm.sh
  chmod +x ${WORKDIR}/stop_pbm.sh
elif [ ! -z "${PBM_DOCKER_IMAGE}" ]; then
  # create startup/stop scripts for the whole PBM setup
  # these get updated at later point
  echo "#!/usr/bin/env bash" > ${WORKDIR}/start_pbm.sh
  chmod +x ${WORKDIR}/start_pbm.sh

  echo "#!/usr/bin/env bash" > ${WORKDIR}/stop_pbm.sh
  chmod +x ${WORKDIR}/stop_pbm.sh

  echo "#!/usr/bin/env bash" > ${WORKDIR}/destroy_pbm.sh
  chmod +x ${WORKDIR}/destroy_pbm.sh

  echo "#!/usr/bin/env bash" > ${WORKDIR}/pbm
  echo "docker exec -i -e PBM_API_TOKEN=${PBM_API_TOKEN} pbm-control pbm \$@" >> ${WORKDIR}/pbm
  chmod +x ${WORKDIR}/pbm
fi
# Create storages config for node agent
if [ ! -z "${PBMDIR}" -o ! -z "${PBM_DOCKER_IMAGE}" ]; then
  if [ "${PBM_STORAGE}" == "fs" -o "${PBM_STORAGE}" == "all" ]; then
    echo "storage:" >> ${WORKDIR}/storage-config.yaml
    echo "  type: filesystem" >> ${WORKDIR}/storage-config.yaml
    echo "  filesystem:" >> ${WORKDIR}/storage-config.yaml
    if [ ! -z "${PBMDIR}" ]; then
      echo "    path: ${WORKDIR}/backup" >> ${WORKDIR}/storage-config.yaml
    elif [ ! -z "${PBM_DOCKER_IMAGE}" ]; then
      echo "    path: /data" >> ${WORKDIR}/storage-config.yaml
    fi
  fi
  if [ "${PBM_STORAGE}" == "minio" -o "${PBM_STORAGE}" == "all" ]; then
    echo "storage:" >> ${WORKDIR}/storage-config.yaml
    echo "  type: s3" >> ${WORKDIR}/storage-config.yaml
    echo "  s3:" >> ${WORKDIR}/storage-config.yaml
    echo "    region: us-west" >> ${WORKDIR}/storage-config.yaml
    echo "    endpointUrl: http://${HOST}:9000" >> ${WORKDIR}/storage-config.yaml
    echo "    bucket: pbm" >> ${WORKDIR}/storage-config.yaml
    echo "    credentials:" >> ${WORKDIR}/storage-config.yaml
    echo "      access-key-id: ${MINIO_ACCESS_KEY_ID}" >> ${WORKDIR}/storage-config.yaml
    echo "      secret-access-key: ${MINIO_SECRET_ACCESS_KEY}" >> ${WORKDIR}/storage-config.yaml
  fi
fi

# Run different configurations
if [ "${LAYOUT}" == "single" ]; then
  start_mongod "${WORKDIR}" "nors" "27017" "${STORAGE_ENGINE}" "${MONGOD_EXTRA}"

  if [[ "${MONGOD_EXTRA}" == *"replSet"* ]]; then
    ${BINDIR}/mongo ${HOST}:27017 --quiet ${SSL_CLIENT} --eval 'rs.initiate()'
    sleep 5
  fi

  if [ ! -z "${AUTH}" ]; then
    ${BINDIR}/mongo localhost:27017/admin --quiet ${SSL_CLIENT} --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] });"
    sed -i "/^AUTH=/c\AUTH=\"--username=\${MONGO_USER} --password=\${MONGO_PASS} --authenticationDatabase=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_AUTH=/c\BACKUP_AUTH=\"--username=\${MONGO_BACKUP_USER} --password=\${MONGO_BACKUP_PASS} --authenticationDatabase=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_DOCKER_AUTH=/c\BACKUP_DOCKER_AUTH=\"-e PBM_AGENT_MONGODB_USERNAME=\${MONGO_BACKUP_USER} -e PBM_AGENT_MONGODB_PASSWORD=\${MONGO_BACKUP_PASS} -e PBM_AGENT_MONGODB-AUTHDB=admin\"" ${WORKDIR}/COMMON
    sed -i "/^BACKUP_URI_AUTH=/c\BACKUP_URI_AUTH=\"\${MONGO_BACKUP_USER}:\${MONGO_BACKUP_PASS}@\"" ${WORKDIR}/COMMON
    ${BINDIR}/mongo ${HOST}:27017/admin ${AUTH} ${SSL_CLIENT} --quiet --eval "db.getSiblingDB(\"admin\").createRole( { role: \"pbmAnyAction\", privileges: [ { resource: { anyResource: true }, actions: [ \"anyAction\" ] } ], roles: [] } )"
    ${BINDIR}/mongo ${HOST}:27017/admin ${AUTH} ${SSL_CLIENT} --quiet --eval "db.createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"readWrite\", collection: \"\" }, { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" }, { db: \"admin\", role: \"pbmAnyAction\" } ] });"
  fi
fi

if [ "${LAYOUT}" == "rs" ]; then
  start_replicaset "${WORKDIR}" "rs1" "27017" "${MONGOD_EXTRA}"
  if [ ! -z "${PBMDIR}" -o ! -z "${PBM_DOCKER_IMAGE}" ]; then
    set_pbm_store
    ${WORKDIR}/start_pbm.sh
  fi
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
  mkdir -p "${WORKDIR}/${RS1NAME}"
  mkdir -p "${WORKDIR}/${RS2NAME}"
  mkdir -p "${WORKDIR}/${CFGRSNAME}"
  mkdir -p "${WORKDIR}/${SHNAME}"

  if [ ${SSL} -eq 1 ]; then
    MONGOS_EXTRA="${MONGOS_EXTRA} --sslMode requireSSL --sslPEMKeyFile ${WORKDIR}/certificates/server.pem --sslCAFile ${WORKDIR}/certificates/ca.crt"
  fi

  echo -e "\n=== Configuring sharding cluster: ${SHNAME} ==="
  # setup config replicaset (3 node)
  start_replicaset "${WORKDIR}/${CFGRSNAME}" "${CFGRSNAME}" "${CFGPORT}" "--configsvr ${CONFIG_EXTRA}"

  # this is needed in 3.6 for MongoRocks since it doesn't support FCV 3.6 and config servers control this in sharding setup
  if [ "${STORAGE_ENGINE}" = "rocksdb" -a "${VERSION_MAJOR}" = "3.6" ]; then
    sleep 15
    ${BINDIR}/mongo "mongodb://${HOST}:${CFGPORT},${HOST}:$(($CFGPORT + 1)),${HOST}:$(($CFGPORT + 2))/?replicaSet=${CFGRSNAME}" --quiet ${SSL_CLIENT} --eval "db.adminCommand({ setFeatureCompatibilityVersion: \"3.4\" });"
  fi

  # setup 2 data replica sets
  start_replicaset "${WORKDIR}/${RS1NAME}" "${RS1NAME}" "${RS1PORT}" "--shardsvr ${MONGOD_EXTRA}"
  start_replicaset "${WORKDIR}/${RS2NAME}" "${RS2NAME}" "${RS2PORT}" "--shardsvr ${MONGOD_EXTRA}"

  # create managing scripts
  echo "#!/usr/bin/env bash" > ${WORKDIR}/${SHNAME}/start_mongos.sh
  echo "echo \"=== Starting sharding server: ${SHNAME} on port ${SHPORT} ===\"" >> ${WORKDIR}/${SHNAME}/start_mongos.sh
  echo "${BINDIR}/mongos --port ${SHPORT} --configdb ${CFGRSNAME}/${HOST}:${CFGPORT},${HOST}:$(($CFGPORT + 1)),${HOST}:$(($CFGPORT + 2)) --logpath ${WORKDIR}/${SHNAME}/mongos.log --fork "$MONGOS_EXTRA" >/dev/null" >> ${WORKDIR}/${SHNAME}/start_mongos.sh
  echo "#!/usr/bin/env bash" > ${WORKDIR}/${SHNAME}/cl_mongos.sh
  echo "source ${WORKDIR}/COMMON" >> ${WORKDIR}/${SHNAME}/cl_mongos.sh
  echo "${BINDIR}/mongo ${HOST}:${SHPORT} \${AUTH} \${SSL_CLIENT} \$@" >> ${WORKDIR}/${SHNAME}/cl_mongos.sh
  ln -s ${WORKDIR}/${SHNAME}/cl_mongos.sh ${WORKDIR}/cl_mongos.sh
  echo "echo \"=== Stopping sharding cluster: ${SHNAME} ===\"" >> ${WORKDIR}/stop_mongodb.sh
  echo "${WORKDIR}/${SHNAME}/stop_mongos.sh" >> ${WORKDIR}/stop_mongodb.sh
  echo "${WORKDIR}/${RS1NAME}/stop_mongodb.sh" >> ${WORKDIR}/stop_mongodb.sh
  echo "${WORKDIR}/${RS2NAME}/stop_mongodb.sh" >> ${WORKDIR}/stop_mongodb.sh
  echo "${WORKDIR}/${CFGRSNAME}/stop_mongodb.sh" >> ${WORKDIR}/stop_mongodb.sh
  echo "#!/usr/bin/env bash" > ${WORKDIR}/${SHNAME}/stop_mongos.sh
  echo "source ${WORKDIR}/COMMON" >> ${WORKDIR}/${SHNAME}/stop_mongos.sh
  echo "echo \"Stopping mongos on port: ${SHPORT}\"" >> ${WORKDIR}/${SHNAME}/stop_mongos.sh
  echo "${BINDIR}/mongo localhost:${SHPORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH} \${SSL_CLIENT}" >> ${WORKDIR}/${SHNAME}/stop_mongos.sh
  echo "#!/usr/bin/env bash" > ${WORKDIR}/start_mongodb.sh
  echo "echo \"Starting sharding cluster on port: ${SHPORT}\"" >> ${WORKDIR}/start_mongodb.sh
  echo "${WORKDIR}/${CFGRSNAME}/start_mongodb.sh" >> ${WORKDIR}/start_mongodb.sh
  echo "${WORKDIR}/${RS1NAME}/start_mongodb.sh" >> ${WORKDIR}/start_mongodb.sh
  echo "${WORKDIR}/${RS2NAME}/start_mongodb.sh" >> ${WORKDIR}/start_mongodb.sh
  echo "${WORKDIR}/${SHNAME}/start_mongos.sh" >> ${WORKDIR}/start_mongodb.sh
  chmod +x ${WORKDIR}/${SHNAME}/start_mongos.sh
  chmod +x ${WORKDIR}/${SHNAME}/stop_mongos.sh
  chmod +x ${WORKDIR}/${SHNAME}/cl_mongos.sh
  chmod +x ${WORKDIR}/start_mongodb.sh
  chmod +x ${WORKDIR}/stop_mongodb.sh
  # start mongos
  ${WORKDIR}/${SHNAME}/start_mongos.sh
  if [ ! -z "${AUTH}" ]; then
    ${BINDIR}/mongo localhost:${SHPORT}/admin --quiet ${SSL_CLIENT} --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\", \"userAdminAnyDatabase\", \"clusterAdmin\" ] });"
    ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} localhost:${SHPORT}/admin --quiet --eval "db.getSiblingDB(\"admin\").createRole( { role: \"pbmAnyAction\", privileges: [ { resource: { anyResource: true }, actions: [ \"anyAction\" ] } ], roles: [] } )"
    ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} localhost:${SHPORT}/admin --quiet --eval "db.createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"readWrite\", collection: \"\" }, { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" }, { db: \"admin\", role: \"pbmAnyAction\" } ] });"
  fi
  # add Shards to the Cluster
  echo "Adding shards to the cluster..."
  sleep 20
  ${BINDIR}/mongo ${HOST}:${SHPORT} --quiet --eval "sh.addShard(\"${RS1NAME}/${HOST}:${RS1PORT}\")" ${AUTH} ${SSL_CLIENT}
  ${BINDIR}/mongo ${HOST}:${SHPORT} --quiet --eval "sh.addShard(\"${RS2NAME}/${HOST}:${RS2PORT}\")" ${AUTH} ${SSL_CLIENT}
  echo -e "\n>>> Enable sharding on specific database with: sh.enableSharding(\"<database>\") <<<"
  echo -e ">>> Shard a collection with: sh.shardCollection(\"<database>.<collection>\", { <key> : <direction> } ) <<<\n"

  # start a PBM agent on the config replica set node (needed here because auth is enabled through mongos)
  #start_pbm_agent "${WORKDIR}/${CFGRSNAME}" "${CFGRSNAME}" "${CFGPORT}"
  if [ ! -z "${PBMDIR}" -o ! -z "${PBM_DOCKER_IMAGE}" ]; then
    for i in 1 2 3; do
      if [ ${RS_ARBITER} != 1 -o ${i} -lt 3 ]; then
        setup_pbm_agent "${WORKDIR}/${CFGRSNAME}/node${i}" "${CFGRSNAME}" "$(($CFGPORT + ${i} - 1))"
      fi
    done
    set_pbm_store
    ${WORKDIR}/start_pbm.sh
  fi
fi
