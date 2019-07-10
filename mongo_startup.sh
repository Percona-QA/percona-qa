#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

# dynamic
MONGO_USER="dba"
MONGO_PASS="test1234"
MONGO_BACKUP_USER="backupUser"
MONGO_BACKUP_PASS="test1234"
PBM_COORDINATOR_API_TOKEN="abcdefgh"
VAULT_SERVER="127.0.0.1"
VAULT_PORT="8200"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-${WORKSPACE}/mongodb-test-vault-token}"
# this is only start of vault secret, additional part is appended per node
VAULT_SECRET="secret_v2/data/psmdb-test"
VAULT_SERVER_CA_FILE="${VAULT_SERVER_CA_FILE:-${WORKSPACE}/test.cer}"
# static or changed with cmd line options
HOST="localhost"
BASEDIR=""
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
AUTH=""
BACKUP_AUTH=""
BACKUP_DOCKER_AUTH=""
SSL=0
SSL_CLIENT=""

if [ -z $1 ]; then
  echo "You need to specify at least one of the options for layout: --single, --rSet, --sCluster or use --help!"
  exit 1
fi

# Check if we have a functional getopt(1)
if ! getopt --test
then
    go_out="$(getopt --options=mrsahe:b:o:t:c:p:d:x \
        --longoptions=single,rSet,sCluster,arbiter,hidden,delayed,help,storageEngine:,binDir:,host:,mongodExtra:,mongosExtra:,configExtra:,encrypt:,cipherMode:,pbmDir:,pbmDocker:,auth,ssl \
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
    echo -e "-o<name>, --host=<name>\t\t instead of localhost specify some hostname for MongoDB setup"
    echo -e "--mongodExtra=\"...\"\t\t specify extra options to pass to mongod"
    echo -e "--mongosExtra=\"...\"\t\t specify extra options to pass to mongos"
    echo -e "--configExtra=\"...\"\t\t specify extra options to pass to config server"
    echo -e "--ssl\t\t\t\t generate ssl certificates and start nodes with requiring ssl connection"
    echo -e "-t, --encrypt\t\t\t enable data at rest encryption (wiredTiger only)"
    echo -e "-c<mode>, --cipherMode=<mode>\t specify cipher mode for encryption (AES256-CBC or AES256-GCM)"
    echo -e "-p<path>, --pbmDir=<path>\t enables Percona Backup for MongoDB (starts agents and coordinator from binaries)"
    echo -e "-d<image>, --pbmDocker=<image>\t starts Percona Backup for MongoDB agents from docker image"
    echo -e "-x, --auth\t\t\t enable authentication"
    echo -e "-h, --help\t\t\t this help"
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
    ;;
  --ssl )
    shift
    SSL=1
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
if [ ${RS_DELAYED} = 1 ] && [ ${RS_ARBITER} = 1 ]; then
  echo "ERROR: Cannot use arbiter and delayed nodes together"
  exit 1
fi
if [ ${RS_DELAYED} = 1 ] && [ ${RS_HIDDEN} = 1 ]; then
  echo "ERROR: Cannot use hidden and delayed nodes together."
  exit 1
fi
if [ ${RS_ARBITER} = 1 ] && [ ${RS_HIDDEN} = 1 ]; then
  echo "ERROR: Cannot use hidden and arbiter nodes together."
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
echo "MONGO_BACKUP_USER=\"${MONGO_BACKUP_USER}\"" >> ${NODESDIR}/COMMON
echo "MONGO_BACKUP_PASS=\"${MONGO_BACKUP_PASS}\"" >> ${NODESDIR}/COMMON
echo "AUTH=\"\"" >> ${NODESDIR}/COMMON
echo "BACKUP_AUTH=\"\"" >> ${NODESDIR}/COMMON
echo "BACKUP_DOCKER_AUTH=\"\"" >> ${NODESDIR}/COMMON
if [ ! -z "${AUTH}" ]; then
  openssl rand -base64 756 > ${NODESDIR}/keyFile
  chmod 400 ${NODESDIR}/keyFile
  MONGOD_EXTRA="${MONGOD_EXTRA} --keyFile ${NODESDIR}/keyFile"
  MONGOS_EXTRA="${MONGOS_EXTRA} --keyFile ${NODESDIR}/keyFile"
  CONFIG_EXTRA="${CONFIG_EXTRA} --keyFile ${NODESDIR}/keyFile"
fi

if [ ${SSL} -eq 1 ]; then
  mkdir -p "${NODESDIR}/certificates"
  pushd "${NODESDIR}/certificates"
  echo -e "\n=== Generating SSL certificates in ${NODESDIR}/certificates ==="
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
  SSL_CLIENT="--ssl --sslCAFile ${NODESDIR}/certificates/ca.crt --sslPEMKeyFile ${NODESDIR}/certificates/client.pem"
  echo "SSL_CLIENT=\"${SSL_CLIENT}\"" >> ${NODESDIR}/COMMON
fi

VERSION_FULL=$(${BINDIR}/mongod --version|head -n1|sed 's/db version v//')
VERSION_MAJOR=$(echo "${VERSION_FULL}"|grep -o '^.\..')

start_pbm_coordinator(){
  mkdir -p "${NODESDIR}/pbm-coordinator/workdir"
  mkdir -p "${NODESDIR}/backup"

  if [ ! -z "${PBMDIR}" ]; then
    # Create startup script for the pbm-coordinator
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    echo "echo \"=== Starting pbm-coordinator on port: 10000 ===\"" >> ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    echo "${PBMDIR}/pbm-coordinator --api-token=${PBM_COORDINATOR_API_TOKEN} --debug --work-dir=${NODESDIR}/pbm-coordinator/workdir --log-file=${NODESDIR}/pbm-coordinator/pbm-coordinator.log 1>${NODESDIR}/pbm-coordinator/stdout.log 2>${NODESDIR}/pbm-coordinator/stderr.log &" >> ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
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

  elif [ ! -z "${PBM_DOCKER_IMAGE}" ]; then
    # Create startup script for the pbm-coordinator from docker image
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/create_pbm_coordinator.sh
    echo "echo \"=== Starting pbm-coordinator on port: 10000 from docker image: ${PBM_DOCKER_IMAGE} ===\"" >> ${NODESDIR}/pbm-coordinator/create_pbm_coordinator.sh
    echo "docker run -d --restart=always --user=$(id -u) --name=pbm-coordinator -e PBM_COORDINATOR_API_TOKEN=${PBM_COORDINATOR_API_TOKEN} -e PBM_COORDINATOR_GRPC_PORT=10000 -e PBM_COORDINATOR_API_PORT=10001 -e PBM_COORDINATOR_WORK_DIR=/data -e PBM_COORDINATOR_LOG_FILE=/logdir/pbm-coordinator.log -p 10000-10001:10000-10001 -v ${NODESDIR}/pbm-coordinator/workdir:/data -v ${NODESDIR}/pbm-coordinator:/logdir ${PBM_DOCKER_IMAGE} pbm-coordinator" >> ${NODESDIR}/pbm-coordinator/create_pbm_coordinator.sh
    chmod +x ${NODESDIR}/pbm-coordinator/create_pbm_coordinator.sh
    ${NODESDIR}/pbm-coordinator/create_pbm_coordinator.sh

    # Create start/stop script for the pbm-coordinator
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    echo "docker start pbm-coordinator" >> ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    chmod +x ${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh
    echo "docker stop pbm-coordinator" >> ${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh
    chmod +x ${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh
    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbm-coordinator/destroy_pbm_coordinator.sh
    echo "docker stop pbm-coordinator" >> ${NODESDIR}/pbm-coordinator/destroy_pbm_coordinator.sh
    echo "docker rm pbm-coordinator" >> ${NODESDIR}/pbm-coordinator/destroy_pbm_coordinator.sh
    chmod +x ${NODESDIR}/pbm-coordinator/destroy_pbm_coordinator.sh

    # create startup/stop scripts for the whole PBM setup
    # these get updated at later point
    echo "#!/usr/bin/env bash" > ${NODESDIR}/start_pbm.sh
    echo "${NODESDIR}/pbm-coordinator/start_pbm_coordinator.sh" >> ${NODESDIR}/start_pbm.sh
    echo "sleep 5" >> ${NODESDIR}/start_pbm.sh
    chmod +x ${NODESDIR}/start_pbm.sh

    echo "#!/usr/bin/env bash" > ${NODESDIR}/stop_pbm.sh
    echo "${NODESDIR}/pbm-coordinator/stop_pbm_coordinator.sh" >> ${NODESDIR}/stop_pbm.sh
    chmod +x ${NODESDIR}/stop_pbm.sh

    echo "#!/usr/bin/env bash" > ${NODESDIR}/destroy_pbm.sh
    echo "${NODESDIR}/pbm-coordinator/destroy_pbm_coordinator.sh" >> ${NODESDIR}/destroy_pbm.sh
    chmod +x ${NODESDIR}/destroy_pbm.sh

    echo "#!/usr/bin/env bash" > ${NODESDIR}/pbmctl
    echo "docker exec -i -e PBMCTL_API_TOKEN=${PBM_COORDINATOR_API_TOKEN} pbm-coordinator pbmctl \$@" >> ${NODESDIR}/pbmctl
    chmod +x ${NODESDIR}/pbmctl
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
    MAUTH="--mongodb-username=\${MONGO_BACKUP_USER} --mongodb-password=\${MONGO_BACKUP_PASS}"
  fi
  if [ "${RS}" != "nors" ]; then
    MREPLICASET="--mongodb-replicaset=${RS}"
  fi

  mkdir -p "${NDIR}/pbm-agent"
  # Create storages config for node agent
  echo "local-filesystem:" > ${NDIR}/pbm-agent/storage-config.yaml
  echo "  type: filesystem" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "  filesystem:" >> ${NDIR}/pbm-agent/storage-config.yaml
  if [ ! -z "${PBMDIR}" ]; then
    echo "    path: ${NODESDIR}/backup" >> ${NDIR}/pbm-agent/storage-config.yaml
  elif [ ! -z "${PBM_DOCKER_IMAGE}" ]; then
    echo "    path: /data" >> ${NDIR}/pbm-agent/storage-config.yaml
  fi
  echo "minio-s3:" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "  type: s3" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "  s3:" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "    region: us-west" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "    endpointUrl: http://${HOST}:9000" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "    bucket: pbm" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "    credentials:" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "      access-key-id: ${MINIO_ACCESS_KEY_ID}" >> ${NDIR}/pbm-agent/storage-config.yaml
  echo "      secret-access-key: ${MINIO_SECRET_ACCESS_KEY}" >> ${NDIR}/pbm-agent/storage-config.yaml

  if [ ! -z "${PBMDIR}" ]; then
    # Create startup script for the agent on the node
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "source ${NODESDIR}/COMMON" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "echo \"=== Starting pbm-agent for mongod on port: ${NPORT} replicaset: ${RS} ===\"" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${PBMDIR}/pbm-agent --debug --mongodb-host=${HOST} --mongodb-port=${NPORT} --storage-config=${NDIR}/pbm-agent/storage-config.yaml --server-address=127.0.0.1:10000 --log-file=${NDIR}/pbm-agent/pbm-agent.log --pid-file=${NDIR}/pbm-agent/pbm-agent.pid ${MREPLICASET} ${MAUTH} 1>${NDIR}/pbm-agent/stdout.log 2>${NDIR}/pbm-agent/stderr.log &" >> ${NDIR}/pbm-agent/start_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/start_pbm_agent.sh
    echo "${NDIR}/pbm-agent/start_pbm_agent.sh" >> ${NODESDIR}/start_pbm.sh
    ${NDIR}/pbm-agent/start_pbm_agent.sh

    # Create stop script for the agent on the node
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/stop_pbm_agent.sh
    echo "kill \$(cat ${NDIR}/pbm-agent/pbm-agent.pid)" >> ${NDIR}/pbm-agent/stop_pbm_agent.sh
    chmod +x ${NDIR}/pbm-agent/stop_pbm_agent.sh

    # create a symlink for pbm-agent binary
    ln -s ${PBMDIR}/pbm-agent ${NDIR}/pbm-agent/pbm-agent

  elif [ ! -z "${PBM_DOCKER_IMAGE}" ]; then
    local CONTAINER_NAME="pbm-agent-${RS}-${NPORT}"
    mkdir -p ${NODESDIR}/backup/pbm-agent-${RS}-${NPORT}

    # Create startup script for the agent from docker image
    echo "#!/usr/bin/env bash" > ${NDIR}/pbm-agent/create_pbm_agent.sh
    echo "source ${NODESDIR}/COMMON" >> ${NDIR}/pbm-agent/create_pbm_agent.sh
    echo "echo \"=== Starting pbm-agent for mongod on port: ${NPORT} replicaset: ${RS} from docker image ===\"" >> ${NDIR}/pbm-agent/create_pbm_agent.sh
    echo "docker run -d --restart=always --user=$(id -u) --name=${CONTAINER_NAME} -e PBM_AGENT_SERVER_ADDRESS=${HOST}:10000 -e PBM_AGENT_BACKUP_DIR=/data -e PBM_AGENT_MONGODB_HOST=${HOST} -e PBM_AGENT_MONGODB_PORT=${NPORT} ${BACKUP_DOCKER_AUTH} -e PBM_AGENT_STORAGE_CONFIG=/logdir/storage-config.yaml -e PBM_AGENT_MONGODB_REPLICASET=${RS} -e PBM_AGENT_LOG_FILE=/logdir/pbm-agent.log -v ${NODESDIR}/backup/${CONTAINER_NAME}:/data -v ${NDIR}/pbm-agent:/logdir ${PBM_DOCKER_IMAGE} pbm-agent" >> ${NDIR}/pbm-agent/create_pbm_agent.sh
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

    echo "${NDIR}/pbm-agent/start_pbm_agent.sh" >> ${NODESDIR}/start_pbm.sh
    echo "${NDIR}/pbm-agent/stop_pbm_agent.sh" >> ${NODESDIR}/stop_pbm.sh
    echo "${NDIR}/pbm-agent/destroy_pbm_agent.sh" >> ${NODESDIR}/destroy_pbm.sh
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
#    openssl req -nodes -newkey rsa:4096 -keyout ${NDIR}/psmdb-${RS}-${PORT}.key -out ${NDIR}/psmdb-${RS}-${PORT}.csr -subj "/C=US/ST=California/L=San Francisco/O=Percona/OU=server/CN=${HOST}/emailAddress=test@percona.com"
#    openssl x509 -req -in ${NDIR}/psmdb-${RS}-${PORT}.csr -CA ${NODESDIR}/certificates/ca.crt -CAkey ${NODESDIR}/certificates/ca.key -set_serial 01 -out ${NDIR}/psmdb-${RS}-${PORT}.crt
#    cat ${NDIR}/psmdb-${RS}-${PORT}.key ${NDIR}/psmdb-${RS}-${PORT}.crt > ${NDIR}/psmdb-${RS}-${PORT}.pem
    EXTRA="${EXTRA} --sslMode requireSSL --sslPEMKeyFile ${NODESDIR}/certificates/server.pem --sslCAFile ${NODESDIR}/certificates/ca.crt"
  fi

  echo "#!/usr/bin/env bash" > ${NDIR}/start.sh
  echo "source ${NODESDIR}/COMMON" >> ${NDIR}/start.sh
  echo "echo \"Starting mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/start.sh
  echo "ENABLE_AUTH=\"\"" >> ${NDIR}/start.sh
  echo "if [ ! -z \"\${AUTH}\" ]; then ENABLE_AUTH=\"--auth\"; fi" >> ${NDIR}/start.sh
  echo "${BINDIR}/mongod \${ENABLE_AUTH} --port ${PORT} --storageEngine ${SE} --dbpath ${NDIR}/db --logpath ${NDIR}/mongod.log --fork ${EXTRA} > /dev/null" >> ${NDIR}/start.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/cl.sh
  echo "source ${NODESDIR}/COMMON" >> ${NDIR}/cl.sh
  echo "${BINDIR}/mongo ${HOST}:${PORT} \${AUTH} \${SSL_CLIENT} \$@" >> ${NDIR}/cl.sh
  echo "#!/usr/bin/env bash" > ${NDIR}/stop.sh
  echo "source ${NODESDIR}/COMMON" >> ${NDIR}/stop.sh
  echo "echo \"Stopping mongod on port: ${PORT} storage engine: ${SE} replica set: ${RS#nors}\"" >> ${NDIR}/stop.sh
  echo "${BINDIR}/mongo ${HOST}:${PORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH} \${SSL_CLIENT}" >> ${NDIR}/stop.sh
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
  echo -e "\n=== Starting replica set: ${RSNAME} ==="
  for i in 1 2 3; do
    if [ "${RSNAME}" != "config" ]; then
      start_mongod "${RSDIR}/node${i}" "${RSNAME}" "$(($RSBASEPORT + ${i} - 1))" "${STORAGE_ENGINE}" "${EXTRA}"
    else
      start_mongod "${RSDIR}/node${i}" "${RSNAME}" "$(($RSBASEPORT + ${i} - 1))" "wiredTiger" "${EXTRA}"
    fi
  done
  sleep 5
  echo "#!/usr/bin/env bash" > ${RSDIR}/init_rs.sh
  echo "source ${NODESDIR}/COMMON" >> ${RSDIR}/init_rs.sh
  echo "echo \"Initializing replica set: ${RSNAME}\"" >> ${RSDIR}/init_rs.sh
  if [ ${RS_ARBITER} = 0 ] && [ ${RS_DELAYED} = 0 ] && [ ${RS_HIDDEN} = 0 ]; then
    if [ "${STORAGE_ENGINE}" == "inMemory" -a "${RSNAME}" != "config" ]; then
      echo "${BINDIR}/mongo ${HOST}:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", writeConcernMajorityJournalDefault: false, members: [{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"${HOST}:$(($RSBASEPORT + 2))\"}]})'" >> ${RSDIR}/init_rs.sh
    else
      echo "${BINDIR}/mongo ${HOST}:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", members: [{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"},{\"_id\":3, \"host\":\"${HOST}:$(($RSBASEPORT + 2))\"}]})'" >> ${RSDIR}/init_rs.sh
    fi
  else
    echo "${BINDIR}/mongo ${HOST}:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'rs.initiate({_id:\"${RSNAME}\", members: [{\"_id\":1, \"host\":\"${HOST}:$(($RSBASEPORT))\"},{\"_id\":2, \"host\":\"${HOST}:$(($RSBASEPORT + 1))\"}]})'" >> ${RSDIR}/init_rs.sh
    echo "sleep 20" >> ${RSDIR}/init_rs.sh
    echo "PRIMARY=\$(${BINDIR}/mongo ${HOST}:$(($RSBASEPORT + 1)) --quiet \${SSL_CLIENT} --eval 'db.runCommand(\"ismaster\").primary' | tail -n1)" >> ${RSDIR}/init_rs.sh
    if [ ${RS_ARBITER} = 1 ]; then
      echo "${BINDIR}/mongo \${PRIMARY} --quiet \${SSL_CLIENT} --eval 'rs.addArb(\"${HOST}:$(($RSBASEPORT + 2))\")'" >> ${RSDIR}/init_rs.sh
    elif [ ${RS_DELAYED} = 1 ]; then
      echo "${BINDIR}/mongo \${PRIMARY} --quiet \${SSL_CLIENT} --eval 'rs.add({host: \"${HOST}:$(($RSBASEPORT + 2))\", priority: 0, votes: 0, hidden: true, slaveDelay: 3600})'" >> ${RSDIR}/init_rs.sh
    elif [ ${RS_HIDDEN} = 1 ]; then
      echo "${BINDIR}/mongo \${PRIMARY} --quiet \${SSL_CLIENT} --eval 'rs.add({host: \"${HOST}:$(($RSBASEPORT + 2))\",  priority: 0, votes: 0, hidden: true})'" >> ${RSDIR}/init_rs.sh
    fi
  fi
  echo "#!/usr/bin/env bash" > ${RSDIR}/stop_all.sh
  echo "echo \"=== Stopping replica set: ${RSNAME} ===\"" >> ${RSDIR}/stop_all.sh
  for cmd in $(find ${RSDIR} -name stop.sh); do
    echo "${cmd}" >> ${RSDIR}/stop_all.sh
  done
  echo "#!/usr/bin/env bash" > ${RSDIR}/start_all.sh
  echo "echo \"=== Starting replica set: ${RSNAME} ===\"" >> ${RSDIR}/start_all.sh
  for cmd in $(find ${RSDIR} -name start.sh); do
    echo "${cmd}" >> ${RSDIR}/start_all.sh
  done
  echo "#!/usr/bin/env bash" > ${RSDIR}/cl_primary.sh
  echo "source ${NODESDIR}/COMMON" >> ${RSDIR}/cl_primary.sh
  if [ "${VERSION_MAJOR}" = "3.2" ]; then
    echo "PRIMARY=\$(${BINDIR}/mongo ${HOST}:$(($RSBASEPORT + 1)) --quiet --eval 'db.runCommand(\"ismaster\").primary' | tail -n1) \${AUTH} \${SSL_CLIENT}" >> ${RSDIR}/cl_primary.sh
    echo "${BINDIR}/mongo \${PRIMARY} \${AUTH} \${SSL_CLIENT} \$@" >> ${RSDIR}/cl_primary.sh
  else
    echo "${BINDIR}/mongo \"mongodb://${HOST}:${RSBASEPORT},${HOST}:$(($RSBASEPORT + 1)),${HOST}:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}\" \${AUTH} \${SSL_CLIENT} \$@" >> ${RSDIR}/cl_primary.sh
  fi
  chmod +x ${RSDIR}/init_rs.sh
  chmod +x ${RSDIR}/start_all.sh
  chmod +x ${RSDIR}/stop_all.sh
  chmod +x ${RSDIR}/cl_primary.sh
  ${RSDIR}/init_rs.sh

  # for config server this is done via mongos
  if [ ! -z "${AUTH}" -a "${RSNAME}" != "config" ]; then
    sleep 10
    ${BINDIR}/mongo "mongodb://localhost:${RSBASEPORT},localhost:$(($RSBASEPORT + 1)),localhost:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}" --quiet ${SSL_CLIENT} --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] });"
    ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} "mongodb://localhost:${RSBASEPORT},localhost:$(($RSBASEPORT + 1)),localhost:$(($RSBASEPORT + 2))/?replicaSet=${RSNAME}" --quiet --eval "db.getSiblingDB(\"admin\").createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" } ] });"
    sed -i "/^AUTH=/c\AUTH=\"${AUTH}\"" ${NODESDIR}/COMMON
    sed -i "/^BACKUP_AUTH=/c\BACKUP_AUTH=\"${BACKUP_AUTH}\"" ${NODESDIR}/COMMON
    sed -i "/^BACKUP_DOCKER_AUTH=/c\BACKUP_DOCKER_AUTH=\"${BACKUP_DOCKER_AUTH}\"" ${NODESDIR}/COMMON
  fi

  # start PBM agents for replica set nodes
  # for config server replica set this is done in another place after cluster user is added
  if [ ! -z "${PBMDIR}${PBM_DOCKER_IMAGE}" -a "${RSNAME}" != "config" ]; then
    sleep 5
    for i in 1 2 3; do
      if [ ${RS_ARBITER} != 1 -o ${i} -lt 3 ]; then
        start_pbm_agent "${RSDIR}/node${i}" "${RSNAME}" "$(($RSBASEPORT + ${i} - 1))" "mongod"
      fi
    done
fi
}

# start PBM coordinator if PBM options specified
if [ ! -z "${PBMDIR}" -o ! -z "${PBM_DOCKER_IMAGE}" ]; then
  start_pbm_coordinator
fi

if [ "${LAYOUT}" == "single" ]; then
  mkdir -p "${NODESDIR}"
  start_mongod "${NODESDIR}" "nors" "27017" "${STORAGE_ENGINE}" "${MONGOD_EXTRA}"

  if [[ "${MONGOD_EXTRA}" == *"replSet"* ]]; then
    ${BINDIR}/mongo ${HOST}:27017 --quiet ${SSL_CLIENT} --eval 'rs.initiate()'
    sleep 5
  fi

  if [ ! -z "${AUTH}" ]; then
    ${BINDIR}/mongo localhost:27017/admin --quiet ${SSL_CLIENT} --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\" ] });"
    sed -i "/^AUTH=/c\AUTH=\"${AUTH}\"" ${NODESDIR}/COMMON
    sed -i "/^BACKUP_AUTH=/c\BACKUP_AUTH=\"${BACKUP_AUTH}\"" ${NODESDIR}/COMMON
    sed -i "/^BACKUP_DOCKER_AUTH=/c\BACKUP_DOCKER_AUTH=\"${BACKUP_DOCKER_AUTH}\"" ${NODESDIR}/COMMON
    ${BINDIR}/mongo localhost:27017/admin ${AUTH} ${SSL_CLIENT} --quiet --eval "db.createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" } ] });"
  fi
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

  if [ ${SSL} -eq 1 ]; then
    MONGOS_EXTRA="${MONGOS_EXTRA} --sslMode requireSSL --sslPEMKeyFile ${NODESDIR}/certificates/server.pem --sslCAFile ${NODESDIR}/certificates/ca.crt"
  fi

  echo -e "\n=== Configuring sharding cluster: ${SHNAME} ==="
  # setup config replicaset (3 node)
  start_replicaset "${NODESDIR}/${CFGRSNAME}" "${CFGRSNAME}" "${CFGPORT}" "--configsvr ${CONFIG_EXTRA}"

  # this is needed in 3.6 for MongoRocks since it doesn't support FCV 3.6 and config servers control this in sharding setup
  if [ "${STORAGE_ENGINE}" = "rocksdb" -a "${VERSION_MAJOR}" = "3.6" ]; then
    sleep 15
    ${BINDIR}/mongo "mongodb://${HOST}:${CFGPORT},${HOST}:$(($CFGPORT + 1)),${HOST}:$(($CFGPORT + 2))/?replicaSet=${CFGRSNAME}" --quiet ${SSL_CLIENT} --eval "db.adminCommand({ setFeatureCompatibilityVersion: \"3.4\" });"
  fi

  # setup 2 data replica sets
  start_replicaset "${NODESDIR}/${RS1NAME}" "${RS1NAME}" "${RS1PORT}" "--shardsvr ${MONGOD_EXTRA}"
  start_replicaset "${NODESDIR}/${RS2NAME}" "${RS2NAME}" "${RS2PORT}" "--shardsvr ${MONGOD_EXTRA}"

  # create managing scripts
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "echo \"=== Starting sharding server: ${SHNAME} on port ${SHPORT} ===\"" >> ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "${BINDIR}/mongos --port ${SHPORT} --configdb ${CFGRSNAME}/${HOST}:${CFGPORT},${HOST}:$(($CFGPORT + 1)),${HOST}:$(($CFGPORT + 2)) --logpath ${NODESDIR}/${SHNAME}/mongos.log --fork "$MONGOS_EXTRA" >/dev/null" >> ${NODESDIR}/${SHNAME}/start_mongos.sh
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/cl_mongos.sh
  echo "source ${NODESDIR}/COMMON" >> ${NODESDIR}/${SHNAME}/cl_mongos.sh
  echo "${BINDIR}/mongo ${HOST}:${SHPORT} \${AUTH} \${SSL_CLIENT} \$@" >> ${NODESDIR}/${SHNAME}/cl_mongos.sh
  ln -s ${NODESDIR}/${SHNAME}/cl_mongos.sh ${NODESDIR}/cl_mongos.sh
  echo "echo \"=== Stopping sharding cluster: ${SHNAME} ===\"" >> ${NODESDIR}/stop_all.sh
  echo "${NODESDIR}/${SHNAME}/stop_mongos.sh" >> ${NODESDIR}/stop_all.sh
  for cmd in $(find ${NODESDIR}/${RSNAME} -name stop.sh); do
    echo "${cmd}" >> ${NODESDIR}/stop_all.sh
  done
  echo "#!/usr/bin/env bash" > ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "source ${NODESDIR}/COMMON" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "echo \"Stopping mongos on port: ${SHPORT}\"" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "${BINDIR}/mongo ${HOST}:${SHPORT}/admin --quiet --eval 'db.shutdownServer({force:true})' \${AUTH} \${SSL_CLIENT}" >> ${NODESDIR}/${SHNAME}/stop_mongos.sh
  echo "#!/usr/bin/env bash" > ${NODESDIR}/start_all.sh
  echo "echo \"Starting sharding cluster on port: ${SHPORT}\"" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${CFGRSNAME}/start_all.sh" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${RS1NAME}/start_all.sh" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${RS2NAME}/start_all.sh" >> ${NODESDIR}/start_all.sh
  echo "${NODESDIR}/${SHNAME}/start_mongos.sh" >> ${NODESDIR}/start_all.sh
  chmod +x ${NODESDIR}/${SHNAME}/start_mongos.sh
  chmod +x ${NODESDIR}/${SHNAME}/stop_mongos.sh
  chmod +x ${NODESDIR}/${SHNAME}/cl_mongos.sh
  chmod +x ${NODESDIR}/start_all.sh
  chmod +x ${NODESDIR}/stop_all.sh
  # start mongos
  ${NODESDIR}/${SHNAME}/start_mongos.sh
  if [ ! -z "${AUTH}" ]; then
    ${BINDIR}/mongo localhost:${SHPORT}/admin --quiet ${SSL_CLIENT} --eval "db.createUser({ user: \"${MONGO_USER}\", pwd: \"${MONGO_PASS}\", roles: [ \"root\", \"userAdminAnyDatabase\", \"clusterAdmin\" ] });"
    ${BINDIR}/mongo ${AUTH} ${SSL_CLIENT} localhost:${SHPORT}/admin --quiet --eval "db.createUser({ user: \"${MONGO_BACKUP_USER}\", pwd: \"${MONGO_BACKUP_PASS}\", roles: [ { db: \"admin\", role: \"backup\" }, { db: \"admin\", role: \"clusterMonitor\" }, { db: \"admin\", role: \"restore\" } ] });"
  fi
  # add Shards to the Cluster
  echo "Adding shards to the cluster..."
  sleep 20
  ${BINDIR}/mongo ${HOST}:${SHPORT} --quiet --eval "sh.addShard(\"${RS1NAME}/${HOST}:${RS1PORT}\")" ${AUTH} ${SSL_CLIENT}
  ${BINDIR}/mongo ${HOST}:${SHPORT} --quiet --eval "sh.addShard(\"${RS2NAME}/${HOST}:${RS2PORT}\")" ${AUTH} ${SSL_CLIENT}
  echo -e "\n>>> Enable sharding on specific database with: sh.enableSharding(\"<database>\") <<<"
  echo -e ">>> Shard a collection with: sh.shardCollection(\"<database>.<collection>\", { <key> : <direction> } ) <<<\n"

  # start a PBM agent on the config replica set node (needed here because auth is enabled through mongos)
  #start_pbm_agent "${NODESDIR}/${CFGRSNAME}" "${CFGRSNAME}" "${CFGPORT}" "mongod"
  if [ ! -z "${PBMDIR}" -o ! -z "${PBM_DOCKER_IMAGE}" ]; then
    for i in 1 2 3; do
      if [ ${RS_ARBITER} != 1 -o ${i} -lt 3 ]; then
        start_pbm_agent "${NODESDIR}/${CFGRSNAME}/node${i}" "${CFGRSNAME}" "$(($CFGPORT + ${i} - 1))" "mongod"
      fi
    done
  fi
fi

