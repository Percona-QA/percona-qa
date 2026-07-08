#!/usr/bin/env bash
# Register a pg_tde KMIP client on Thales CipherTrust Manager and export PEMs for pytest.
#
# CipherTrust issues the client certificate when you register a KMIP client with a
# registration token — you do not upload locally generated certs for this flow.
#
# Based on the working CTM lab sequence:
#   auth → create Key Admins user → KMIP profile → registration token →
#   interface tls-pw-opt → register client → write PEMs (sed newline fix)
#
# Usage (run directly — do not source):
#   cd postgresql/pytest
#   export CTM_IP=35.158.186.61
#   export CTM_ADMIN_PASSWORD='...'
#   ./scripts/setup_ciphertrust_kmip.sh --cert-dir ~/thales_pgtde_certs
#
#   source ~/thales_pgtde_certs/ciphertrust_kmip_pytest.env
#   KMIP_PROFILE=thales ./scripts/run_kmip_matrix.sh
#
# See docs/kmip/README.md and config/kmip_profiles.example.env (KMIP_THALES_*).
set -euo pipefail

CTM_IP="${CTM_IP:-}"
CTM_ADMIN_USER="${CTM_ADMIN_USER:-admin}"
CTM_ADMIN_PASSWORD="${CTM_ADMIN_PASSWORD:-${ADMIN_PASS:-}}"
CTM_ADMIN_PASSWORD_FILE="${CTM_ADMIN_PASSWORD_FILE:-}"

KMIP_HOST="${CTM_KMIP_HOST:-}"
KMIP_PORT="${CTM_KMIP_PORT:-5696}"
PROFILE_NAME="${CTM_KMIP_PROFILE_NAME:-pgtde_profile}"
CLIENT_NAME="${CTM_KMIP_CLIENT_NAME:-pgtde-client-node1}"
NAME_PREFIX="${CTM_KMIP_NAME_PREFIX:-pgtde}"
SKIP_INTERFACE_PATCH="${CTM_SKIP_INTERFACE_PATCH:-0}"
SKIP_USER_CREATE="${CTM_SKIP_USER_CREATE:-0}"
INSTALL_FOR_POSTGRES="${CTM_INSTALL_FOR_POSTGRES:-0}"
PG_CERT_DIR="${CTM_PG_CERT_DIR:-}"

# CTM local user mapped via cert CN (Key Admins) — required for some CTM policies.
CTM_KMIP_USER="${CTM_KMIP_USER:-pgtdeuser}"
CTM_KMIP_USER_PASSWORD="${CTM_KMIP_USER_PASSWORD:-SecurePgPass123!}"

CERT_DIR="${CTM_KMIP_CERT_DIR:-${HOME}/thales_pgtde_certs}"
ENV_FILE="${CTM_KMIP_ENV_FILE:-${CERT_DIR}/ciphertrust_kmip_pytest.env}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Register a KMIP client on Thales CipherTrust Manager for pg_tde / pytest.
CipherTrust returns client key, client cert, and server CA PEMs (registration-token flow).

Required (env or flags):
  CTM_IP / --ctm-ip              CipherTrust Manager hostname or IP (REST API)
  CTM_ADMIN_PASSWORD / --admin-password
                                 Admin password (or CTM_ADMIN_PASSWORD_FILE / ADMIN_PASS)

Optional:
  CTM_ADMIN_USER                 REST API user (default: admin)
  CTM_KMIP_HOST                  KMIP endpoint host (default: CTM_IP)
  CTM_KMIP_PORT                  KMIP port (default: 5696)
  CTM_KMIP_PROFILE_NAME          KMIP client profile (default: pgtde_profile)
  CTM_KMIP_CLIENT_NAME           Registered client name (default: pgtde-client-node1)
  CTM_KMIP_NAME_PREFIX           Registration token name prefix (default: pgtde)
  CTM_KMIP_USER                  Local CTM user for cert CN mapping (default: pgtdeuser)
  CTM_KMIP_USER_PASSWORD         Password for that user (default: SecurePgPass123!)
  CTM_KMIP_CERT_DIR / --cert-dir Output directory for PEM files
                                 (default: \$HOME/thales_pgtde_certs)
  CTM_KMIP_ENV_FILE              Pytest env file (KMIP_THALES_*)
  CTM_SKIP_INTERFACE_PATCH=1     Skip KMIP interface mode PATCH (tls-pw-opt)
  CTM_SKIP_USER_CREATE=1         Skip create user + Key Admins assignment
  CTM_PG_CERT_DIR                If set, copy PEMs here owned by postgres
  --install-for-postgres         Same as CTM_PG_CERT_DIR=/var/lib/postgresql/pg_tde_kmip/thales
  -h, --help                     Show this help

Examples:
  export CTM_IP=35.158.186.61 CTM_ADMIN_PASSWORD='secret'
  ./scripts/setup_ciphertrust_kmip.sh --cert-dir ~/thales_pgtde_certs

  source ~/thales_pgtde_certs/ciphertrust_kmip_pytest.env
  KMIP_PROFILE=thales pytest tests/test_kmip.py -v

pg_tde SQL (after shared_preload_libraries + CREATE EXTENSION pg_tde):
  SELECT pg_tde_add_global_key_provider_kmip(
    'thales_ctm', '<kmip-host>', 5696,
    '<cert-dir>/pgtde-client-cert.pem',
    '<cert-dir>/pgtde-client-key.pem',
    '<cert-dir>/pgtde-server-ca.pem');
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

ctm_api() {
    local method="$1"
    local path="$2"
    shift 2
    curl -sk -X "$method" "https://${CTM_IP}${path}" \
        -H "Authorization: Bearer ${JWT}" \
        -H "Content-Type: application/json" \
        "$@"
}

# CipherTrust PEM fields may contain literal "\n"; sed matches the working lab script.
write_pem_from_json() {
    local field="$1"
    local dest="$2"
    local json="$3"
    echo "${json}" | jq -r ".${field}" | sed 's/\\n/\n/g' > "${dest}"
}

validate_pem_file() {
    local label="$1"
    local path="$2"
    local kind="$3"
    [[ -s "${path}" ]] || die "${label} is empty: ${path}"
    grep -q '^-----BEGIN ' "${path}" || die "${label} is not PEM (missing -----BEGIN): ${path}"
    if command -v openssl >/dev/null 2>&1; then
        if [[ "${kind}" == "pkey" ]]; then
            openssl pkey -in "${path}" -noout >/dev/null 2>&1 \
                || die "${label} failed openssl parse: ${path}"
        else
            openssl x509 -in "${path}" -noout >/dev/null 2>&1 \
                || die "${label} failed openssl parse: ${path}"
        fi
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ctm-ip)              CTM_IP="$2"; shift 2 ;;
        --admin-user)          CTM_ADMIN_USER="$2"; shift 2 ;;
        --admin-password)      CTM_ADMIN_PASSWORD="$2"; shift 2 ;;
        --kmip-host)           KMIP_HOST="$2"; shift 2 ;;
        --kmip-port)           KMIP_PORT="$2"; shift 2 ;;
        --profile-name)        PROFILE_NAME="$2"; shift 2 ;;
        --client-name)         CLIENT_NAME="$2"; shift 2 ;;
        --name-prefix)         NAME_PREFIX="$2"; shift 2 ;;
        --kmip-user)           CTM_KMIP_USER="$2"; shift 2 ;;
        --kmip-user-password)  CTM_KMIP_USER_PASSWORD="$2"; shift 2 ;;
        --cert-dir)            CERT_DIR="$2"; ENV_FILE="${CERT_DIR}/ciphertrust_kmip_pytest.env"; shift 2 ;;
        --env-file)            ENV_FILE="$2"; shift 2 ;;
        --skip-interface-patch) SKIP_INTERFACE_PATCH=1; shift ;;
        --skip-user-create)    SKIP_USER_CREATE=1; shift ;;
        --install-for-postgres) INSTALL_FOR_POSTGRES=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

if [[ -z "${CTM_IP}" || ( -z "${CTM_ADMIN_PASSWORD}" && -z "${CTM_ADMIN_PASSWORD_FILE}" ) ]]; then
    usage
    exit 0
fi

need_cmd curl
need_cmd jq

if [[ -n "${CTM_ADMIN_PASSWORD_FILE}" ]]; then
    [[ -f "${CTM_ADMIN_PASSWORD_FILE}" ]] || die "CTM_ADMIN_PASSWORD_FILE not found: ${CTM_ADMIN_PASSWORD_FILE}"
    CTM_ADMIN_PASSWORD="$(tr -d '[:space:]' < "${CTM_ADMIN_PASSWORD_FILE}")"
fi
[[ -n "${CTM_ADMIN_PASSWORD}" ]] || die "CTM_ADMIN_PASSWORD is required (export, --admin-password, or CTM_ADMIN_PASSWORD_FILE)"

KMIP_HOST="${KMIP_HOST:-${CTM_IP}}"

CLIENT_CERT="${CERT_DIR}/pgtde-client-cert.pem"
CLIENT_KEY="${CERT_DIR}/pgtde-client-key.pem"
SERVER_CA="${CERT_DIR}/pgtde-server-ca.pem"

mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

echo "=============================================================================="
echo "CipherTrust Manager: https://${CTM_IP}"
echo "KMIP endpoint:       ${KMIP_HOST}:${KMIP_PORT}"
echo "Cert directory:      ${CERT_DIR}"
echo "=============================================================================="

# ── 1) Admin JWT ───────────────────────────────────────────────────────────────
echo "Step 1: Authenticating to CipherTrust..."
AUTH_RESP="$(curl -sk -X POST "https://${CTM_IP}/api/v1/auth/tokens/" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${CTM_ADMIN_USER}\",\"password\":\"${CTM_ADMIN_PASSWORD}\",\"validity_period\":86400}")"

JWT="$(echo "${AUTH_RESP}" | jq -r '.jwt // empty')"
[[ -n "${JWT}" && "${JWT}" != "null" ]] \
    || die "admin authentication failed: $(echo "${AUTH_RESP}" | jq -c '.' 2>/dev/null || echo "${AUTH_RESP}")"
echo "Authenticated as ${CTM_ADMIN_USER}"

# ── 2) Local user + Key Admins (cert CN mapping) ───────────────────────────────
if [[ "${SKIP_USER_CREATE}" != "1" ]]; then
    echo "Step 2: Creating local CTM user for certificate mapping (${CTM_KMIP_USER})..."
    USER_RESP="$(ctm_api POST "/api/v1/usermgmt/users/" \
        -d "{
            \"username\":\"${CTM_KMIP_USER}\",
            \"password\":\"${CTM_KMIP_USER_PASSWORD}\",
            \"email\":\"${CTM_KMIP_USER}@example.com\"
        }")" || true

    USER_ID="$(echo "${USER_RESP}" | jq -r '.user_id // empty')"
    if [[ -n "${USER_ID}" && "${USER_ID}" != "null" ]]; then
        ctm_api POST "/api/v1/usermgmt/groups/Key%20Admins/users/${USER_ID}" >/dev/null || true
        echo "User ${CTM_KMIP_USER} created and assigned to Key Admins"
    else
        warn "User create skipped or already exists: $(echo "${USER_RESP}" | jq -c '.' 2>/dev/null || echo "${USER_RESP}")"
    fi
else
    echo "Step 2: Skipping user create (CTM_SKIP_USER_CREATE=1)"
fi

# ── 3) KMIP profile ────────────────────────────────────────────────────────────
echo "Step 3: Creating KMIP profile (${PROFILE_NAME})..."
PROFILE_RESP="$(ctm_api POST "/api/v1/kmip/kmip-profiles" \
    --data-binary "{
        \"name\": \"${PROFILE_NAME}\",
        \"subject_dn_field_to_modify\": \"UID\",
        \"properties\": {
            \"cert_user_field\": \"CN\"
        },
        \"device_credential\": {}
    }")" || true

if echo "${PROFILE_RESP}" | jq -e '.name // .id' >/dev/null 2>&1; then
    echo "KMIP profile ready: ${PROFILE_NAME}"
else
    warn "KMIP profile create skipped or already exists: $(echo "${PROFILE_RESP}" | jq -c '.' 2>/dev/null || echo "${PROFILE_RESP}")"
fi

# ── 4) Registration token ──────────────────────────────────────────────────────
echo "Step 4: Generating registration token..."
TOKEN_RESP="$(ctm_api POST "/api/v1/kmip/regtokens/" \
    -d "{
        \"name_prefix\":\"${NAME_PREFIX}\",
        \"profile_name\":\"${PROFILE_NAME}\",
        \"max_clients\":100
    }")"

TOKEN="$(echo "${TOKEN_RESP}" | jq -r '.token // empty')"
[[ -n "${TOKEN}" && "${TOKEN}" != "null" ]] \
    || die "registration token failed: $(echo "${TOKEN_RESP}" | jq -c '.' 2>/dev/null || echo "${TOKEN_RESP}")"
echo "Registration token created (prefix: ${NAME_PREFIX})"

# ── 5) KMIP interface mode ─────────────────────────────────────────────────────
if [[ "${SKIP_INTERFACE_PATCH}" != "1" ]]; then
    echo "Step 5: Configuring KMIP interface mode (tls-pw-opt)..."
    IFACE_RESP="$(ctm_api PATCH "/api/v1/configs/interfaces/kmip" \
        -d '{"mode": "tls-pw-opt"}')" || true
    if echo "${IFACE_RESP}" | jq -e '.mode // .interface // .id' >/dev/null 2>&1; then
        echo "KMIP interface mode set to tls-pw-opt"
    else
        warn "KMIP interface PATCH response: $(echo "${IFACE_RESP}" | jq -c '.' 2>/dev/null || echo "${IFACE_RESP}")"
    fi
else
    echo "Step 5: Skipping KMIP interface PATCH (CTM_SKIP_INTERFACE_PATCH=1)"
fi

# ── 6) Register client + write PEMs ────────────────────────────────────────────
echo "Step 6: Registering client (${CLIENT_NAME}) and writing certificates..."
CLIENT_RESP="$(ctm_api POST "/api/v1/kmip/kmip-clients" \
    -d "{
        \"name\":\"${CLIENT_NAME}\",
        \"reg_token\":\"${TOKEN}\"
    }")"

if echo "${CLIENT_RESP}" | grep -qi '"error\|"code"\|message.*fail'; then
    if ! echo "${CLIENT_RESP}" | jq -e '.key and .cert and .client_ca' >/dev/null 2>&1; then
        echo "ERROR FROM THALES SERVER:" >&2
        echo "${CLIENT_RESP}" | jq '.' 2>/dev/null || echo "${CLIENT_RESP}" >&2
        exit 1
    fi
fi

# Match working lab script: jq -r + sed literal-\n → real newlines (OpenSSL needs this).
write_pem_from_json key "${CLIENT_KEY}" "${CLIENT_RESP}"
write_pem_from_json cert "${CLIENT_CERT}" "${CLIENT_RESP}"
write_pem_from_json client_ca "${SERVER_CA}" "${CLIENT_RESP}"

validate_pem_file "client key" "${CLIENT_KEY}" pkey
validate_pem_file "client cert" "${CLIENT_CERT}" x509
validate_pem_file "server CA" "${SERVER_CA}" x509

chmod 600 "${CLIENT_KEY}"
chmod 644 "${CLIENT_CERT}" "${SERVER_CA}"

if [[ "${INSTALL_FOR_POSTGRES}" == "1" || -n "${PG_CERT_DIR}" ]]; then
    _pg_dir="${PG_CERT_DIR:-/var/lib/postgresql/pg_tde_kmip/thales}"
    echo "Installing PEMs for postgres OS user under ${_pg_dir}"
    if [[ "$(id -u)" -ne 0 ]]; then
        sudo mkdir -p "${_pg_dir}"
        sudo install -o postgres -g postgres -m 600 "${CLIENT_KEY}" "${_pg_dir}/pgtde-client-key.pem"
        sudo install -o postgres -g postgres -m 644 "${CLIENT_CERT}" "${_pg_dir}/pgtde-client-cert.pem"
        sudo install -o postgres -g postgres -m 644 "${SERVER_CA}" "${_pg_dir}/pgtde-server-ca.pem"
    else
        mkdir -p "${_pg_dir}"
        install -o postgres -g postgres -m 600 "${CLIENT_KEY}" "${_pg_dir}/pgtde-client-key.pem"
        install -o postgres -g postgres -m 644 "${CLIENT_CERT}" "${_pg_dir}/pgtde-client-cert.pem"
        install -o postgres -g postgres -m 644 "${SERVER_CA}" "${_pg_dir}/pgtde-server-ca.pem"
    fi
    CLIENT_CERT="${_pg_dir}/pgtde-client-cert.pem"
    CLIENT_KEY="${_pg_dir}/pgtde-client-key.pem"
    SERVER_CA="${_pg_dir}/pgtde-server-ca.pem"
fi

cat > "${ENV_FILE}" <<EOF
# source this file before pytest with KMIP_PROFILE=thales
export KMIP_THALES_HOST=${KMIP_HOST}
export KMIP_THALES_PORT=${KMIP_PORT}
export KMIP_THALES_CLIENT_CERT=${CLIENT_CERT}
export KMIP_THALES_CLIENT_KEY=${CLIENT_KEY}
export KMIP_THALES_SERVER_CA=${SERVER_CA}
EOF

echo "=============================================================================="
echo "SUCCESS! Certificates written to ${CERT_DIR}"
ls -l "${CERT_DIR}"/pgtde-*.pem 2>/dev/null || ls -l "${CLIENT_CERT}" "${CLIENT_KEY}" "${SERVER_CA}"
echo ""
echo "Pytest env: ${ENV_FILE}"
echo "  source ${ENV_FILE}"
echo "  KMIP_PROFILE=thales ./scripts/run_kmip_matrix.sh"
echo ""
echo "Ensure postgres can read PEMs if using system PostgreSQL:"
echo "  sudo -u postgres openssl x509 -in '${CLIENT_CERT}' -noout -subject"
echo ""
echo "pg_tde SQL:"
echo "  SELECT pg_tde_add_global_key_provider_kmip("
echo "    'thales_ctm', '${KMIP_HOST}', ${KMIP_PORT},"
echo "    '${CLIENT_CERT}', '${CLIENT_KEY}', '${SERVER_CA}');"

if command -v openssl >/dev/null 2>&1; then
    echo ""
    openssl x509 -in "${CLIENT_CERT}" -noout -subject -dates 2>/dev/null \
        | sed 's/^/  cert: /' || true
fi
