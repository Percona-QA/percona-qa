#!/usr/bin/env bash
# Created by Tomislav Plavcic, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)

GEN_MYSQL_CONFIG=1
USE_SSL=0
GEN_VAULT_CONFIG=1
DL_VAULT=1
INIT_VAULT=1
VAULT_DEV_MODE=0
WORKDIR=""
VAULT_PORT="8200"
VAULT_PROTOCOL="http"

usage(){
  echo -e "\nThis script generates vault config, mysql keyring plugin config, ssl certificates and starts vault server."
  echo -e "start_vault.sh script is also generated in workdir to just start and unseal vault if it's stopped."
  echo -e "Usage:"
  echo -e "  vault_test_setup --workdir=<path>"
  echo -e ""
  echo -e "By default Vault config and MySQL config will be generated and Vault server initialized and started."
  echo -e "SSL is not enabled by default, see options to use that."
  echo -e "If vault binary is not present in workdir it will be downloaded automatically."
  echo -e ""
  echo -e "Additional options are:"
  echo -e "  --use-ssl, -s                 Generate SSL certificates and use https for communication with vault."
  echo -e "  --vault-dev-mode, -d          This starts vault in dev mode"
  echo -e "                                (inmemory, no persistance, no ssl, no config, unsealed, default port: 8200)"
  echo -e "  --workdir=<path>, -w<path>    Directory where vault will be setup and additional directories created (mandatory)."
  echo -e "  --setup-pxc-mount-points, -m  This will create 3 mount points in vault server for Percona XtraDB Cluster"
  echo -e "  --help, -h                    This help screen.\n"
}

# Check if we have a functional getopt(1)
if ! getopt --test
  then
  go_out="$(getopt --options=sw:dmh \
  --longoptions=use-ssl,workdir:,vault-dev-mode,setup-pxc-mount-points,help \
  --name="$(basename "$0")" -- "$@")"
  test $? -eq 0 || exit 1
  eval set -- $go_out
fi

for arg
do
  case "$arg" in
    -- ) shift; break;;
    -s | --use-ssl )
    USE_SSL=1
    shift
    ;;
    -w | --workdir )
    WORKDIR="$2"
    shift 2
    ;;
    -d | --vault-dev-mode )
    VAULT_DEV_MODE=1
    shift
    ;;
    -m | --setup-pxc-mount-points  )
    SETUP_PXC_MOUNT_POINTS=1
    shift
    ;;
    -h | --help )
    usage
    exit 0
    ;;
  esac
done

if [[ -z "${WORKDIR}" ]]; then
  echo "ERROR: Working directory parameter is mandatory!"
  usage
  exit 1
fi

if [[ -z "$(which openssl)" && ${USE_SSL} -eq 1 ]]; then
  echo "ERROR: openssl is required for proper functioning of this script!"
  exit 1
fi

if [[ -z "$(which unzip)" && ${DL_VAULT} -eq 1 ]]; then
  echo "ERROR: unzip utility is required if downloading vault from web!"
  exit 1
fi

if [[ -z "$(which wget)" && ${DL_VAULT} -eq 1 ]]; then
  echo "ERROR: wget utility is required if downloading vault from web!"
  exit 1
fi

cd ${WORKDIR}

if [[ ${DL_VAULT} -eq 1 ]]; then
  if [[ -x "${WORKDIR}/vault" ]]; then
    echo "Vault binary already present, skipping download..."
  else
    echo "Downloading vault binary..."
    VAULT_URL=$(${SCRIPT_PWD}/get_download_link.sh --product=vault)
    wget "${VAULT_URL}" > /dev/null 2>&1
    VAULT_ZIP=$(echo "${VAULT_URL}"|grep -oP "vault_.*linux.*.zip")
    unzip "${VAULT_ZIP}" > /dev/null
    rm -f "${VAULT_ZIP}"
    echo "Vault binary is ready."
  fi
fi

echo "#!/usr/bin/env bash" > ${WORKDIR}/start_vault.sh
chmod +x ${WORKDIR}/start_vault.sh

if [[ ${USE_SSL} -eq 1 ]]; then
  VAULT_PROTOCOL="https"
  if [[ ! -d "" ]]; then
    mkdir -p ${WORKDIR}/certificates
  fi
  cd ${WORKDIR}/certificates
  echo -e "\nGenerating SSL certificates in: ${WORKDIR}/certificates"
  openssl req -newkey rsa:2048 -days 3650 -x509 -nodes -out root.cer -subj "/C=GB/ST=London/L=London/O=Global Security/OU=IT Department/CN=example.com" >/dev/null 2>&1
  openssl req -newkey rsa:1024 -nodes -out vault.csr -keyout vault.key -subj "/C=GB/ST=London/L=London/O=Global Security/OU=IT Department/CN=example.com" >/dev/null 2>&1
  echo 000a > serialfile
  touch certindex
  echo "[ ca ]" > ${WORKDIR}/certificates/vault-ca.conf
  echo "default_ca = myca" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "[ myca ]" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "new_certs_dir = /tmp" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "unique_subject = no" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "certificate = ${WORKDIR}/certificates/root.cer" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "database = ${WORKDIR}/certificates/certindex" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "private_key = ${WORKDIR}/certificates/privkey.pem" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "serial = ${WORKDIR}/certificates/serialfile" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "default_days = 365" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "default_md = sha1" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "policy = myca_policy" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "x509_extensions = myca_extensions" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "copy_extensions = copy" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "[ myca_policy ]" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "commonName = supplied" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "stateOrProvinceName = supplied" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "countryName = supplied" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "emailAddress = optional" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "organizationName = supplied" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "organizationalUnitName = optional" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "[ myca_extensions ]" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "basicConstraints = CA:false" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "subjectKeyIdentifier = hash" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "authorityKeyIdentifier = keyid:always" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "subjectAltName = IP:127.0.0.1" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "keyUsage = digitalSignature,keyEncipherment" >> ${WORKDIR}/certificates/vault-ca.conf
  echo "extendedKeyUsage = serverAuth" >> ${WORKDIR}/certificates/vault-ca.conf
  openssl ca -batch -config vault-ca.conf -notext -in vault.csr -out vault.crt >/dev/null 2>&1
  cd ${WORKDIR}
fi

if [[ ${GEN_VAULT_CONFIG} -eq 1 && ${VAULT_DEV_MODE} -eq 0 ]]; then
  echo -e "\nGenerating vault config file in: ${WORKDIR}/vault_config.hcl"
  echo "disable_mlock = true" > ${WORKDIR}/vault_config.hcl
  echo "default_lease_ttl = \"24h\"" >> ${WORKDIR}/vault_config.hcl
  echo "max_lease_ttl = \"24h\"" >> ${WORKDIR}/vault_config.hcl
  echo -e "\nstorage \"file\" {" >> ${WORKDIR}/vault_config.hcl
  echo "  path = \"${WORKDIR}/vault_data\"" >> ${WORKDIR}/vault_config.hcl
  echo "}" >> ${WORKDIR}/vault_config.hcl
  echo -e "\nlistener \"tcp\" {" >> ${WORKDIR}/vault_config.hcl
  echo "  address = \"127.0.0.1:${VAULT_PORT}\"" >> ${WORKDIR}/vault_config.hcl
  if [[ ${USE_SSL} -eq 1 ]]; then
    echo "  tls_cert_file = \"${WORKDIR}/certificates/vault.crt\"" >> ${WORKDIR}/vault_config.hcl
    echo "  tls_key_file = \"${WORKDIR}/certificates/vault.key\"" >> ${WORKDIR}/vault_config.hcl
  else
    echo "  tls_disable = 1" >> ${WORKDIR}/vault_config.hcl
  fi
  echo "}" >> ${WORKDIR}/vault_config.hcl
fi

if [[ ${INIT_VAULT} -eq 1 ]]; then
  if [[ ! -d "${WORKDIR}/vault_data" ]]; then
    mkdir -p "${WORKDIR}/vault_data"
  fi
  if [[ ${VAULT_DEV_MODE} -eq 1 ]]; then
    echo -e "\nInitializing vault server in development mode..."
    VAULT_PORT="8200"
    echo "Vault output located in: ${WORKDIR}/vault_output.txt"
    CMD="nohup ${WORKDIR}/vault server -dev >${WORKDIR}/vault_output.txt 2>&1 &"
    eval $CMD
    echo "$CMD" >> ${WORKDIR}/start_vault.sh
    sleep 3
    ROOT_TOKEN=$(grep "Root Token: " ${WORKDIR}/vault_output.txt|sed 's/Root Token: //')
  else
    echo -e "\nInitializing vault server in standard mode..."
    echo "Vault output located in: ${WORKDIR}/vault_output.txt"
    echo "Vault keys located in: ${WORKDIR}/vault_keys.txt"
    CMD="nohup ${WORKDIR}/vault server -config=${WORKDIR}/vault_config.hcl >${WORKDIR}/vault_output.txt 2>&1 &"
    eval $CMD
    echo "$CMD" >> ${WORKDIR}/start_vault.sh
    CMD="sleep 3"
    eval $CMD
    echo "$CMD" >> ${WORKDIR}/start_vault.sh
    ${WORKDIR}/vault operator init -address=${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT} -tls-skip-verify > ${WORKDIR}/vault_keys.txt
    UNSEAL_KEY1=$(grep "Unseal Key 1: " ${WORKDIR}/vault_keys.txt|sed 's/Unseal Key 1: //')
    UNSEAL_KEY2=$(grep "Unseal Key 2: " ${WORKDIR}/vault_keys.txt|sed 's/Unseal Key 2: //')
    UNSEAL_KEY3=$(grep "Unseal Key 3: " ${WORKDIR}/vault_keys.txt|sed 's/Unseal Key 3: //')
    ROOT_TOKEN=$(grep "Initial Root Token: " ${WORKDIR}/vault_keys.txt|sed 's/Initial Root Token: //')
    CMD="${WORKDIR}/vault operator unseal -address=${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT} -tls-skip-verify ${UNSEAL_KEY1} >/dev/null"
    eval $CMD
    echo "$CMD" >> ${WORKDIR}/start_vault.sh
    CMD="${WORKDIR}/vault operator unseal -address=${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT} -tls-skip-verify ${UNSEAL_KEY2} >/dev/null"
    eval $CMD
    echo "$CMD" >> ${WORKDIR}/start_vault.sh
    CMD="${WORKDIR}/vault operator unseal -address=${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT} -tls-skip-verify ${UNSEAL_KEY3} >/dev/null"
    eval $CMD
    echo "$CMD" >> ${WORKDIR}/start_vault.sh
  fi
fi

if [[ ${GEN_MYSQL_CONFIG} -eq 1 ]]; then
  echo -e "\nGenerating MySQL config file..."
  echo "Keyring vault plugin config file located in: ${WORKDIR}/keyring_vault.cnf"
  echo "vault_url = ${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT}" > ${WORKDIR}/keyring_vault.cnf
  echo "secret_mount_point = secret" >> ${WORKDIR}/keyring_vault.cnf
  echo "token = ${ROOT_TOKEN}" >> ${WORKDIR}/keyring_vault.cnf
  if [[ ${USE_SSL} -eq 1 ]]; then
    echo "vault_ca = ${WORKDIR}/certificates/root.cer" >> ${WORKDIR}/keyring_vault.cnf
  fi
  echo -e "\nUse following mysql parameters for connecting to this vault server:"
  echo "--early-plugin-load=keyring_vault=keyring_vault.so --loose-keyring_vault_config=${WORKDIR}/keyring_vault.cnf"
fi

if [[ $SETUP_PXC_MOUNT_POINTS -eq 1 ]];then
  echo -e "\nGenerating mount points for Percona XtraDB Cluster..."
  export VAULT_ADDR=${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT}
  export VAULT_TOKEN=${ROOT_TOKEN}
  for i in `seq 1 3`; do
    ${WORKDIR}/vault mount -tls-skip-verify -path=pxc_node${i} generic 2>/dev/null
    echo "vault_url = ${VAULT_PROTOCOL}://127.0.0.1:${VAULT_PORT}" > ${WORKDIR}/keyring_vault_pxc${i}.cnf
    echo "secret_mount_point = pxc_node${i}" >> ${WORKDIR}/keyring_vault_pxc${i}.cnf
    echo "token = ${ROOT_TOKEN}" >> ${WORKDIR}/keyring_vault_pxc${i}.cnf
    echo "Vault configuration for PXC node${i} : ${WORKDIR}/keyring_vault_pxc${i}.cnf"
    if [[ ${USE_SSL} -eq 1 ]]; then
      echo "vault_ca = ${WORKDIR}/certificates/root.cer" >> ${WORKDIR}/keyring_vault_pxc${i}.cnf
    fi
  done
fi
