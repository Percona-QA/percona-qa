#!/usr/bin/env bash
# Self-contained OpenBao (Vault KV v2) bootstrap for PG-2609 repro / workaround
# scripts. Sourced from this directory — does NOT depend on
# postgresql/pytest/scripts/setup_openbao_for_pytest.sh.
#
# Exports (when bootstrap succeeds):
#   VAULT_ADDR, VAULT_TOKEN_FILE, VAULT_TOKEN (unset in favor of file),
#   VAULT_SECRET_MOUNT, VAULT_NAMESPACE, OPENBAO_BIN, OPENBAO_PID (if spawned)
#
# Usage from a PG-2609_*.sh script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=PG-2609_openbao_setup.sh
#   source "$SCRIPT_DIR/PG-2609_openbao_setup.sh"
#   pg2609_ensure_openbao   # starts bao if needed
#
# Env:
#   AUTO_OPENBAO=1          (default) spawn local bao when VAULT_* missing
#   OPENBAO_FORCE_RESTART=1 kill existing bao and start fresh
#   OPENBAO_RUN_DIR=...     default: $REPRO_ROOT/openbao or /tmp/PG-2609_openbao
#   OPENBAO_ADDR=...        default http://127.0.0.1:8200
#   OPENBAO_MOUNT=...       default pg_tde
#   OPENBAO_NAMESPACE=...   default pg_tde_ns1 (exported with trailing /)

# shellcheck disable=SC2034
PG2609_OPENBAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"
PG2609_OPENBAO_MOUNT="${OPENBAO_MOUNT:-pg_tde}"
PG2609_OPENBAO_NS="${OPENBAO_NAMESPACE:-pg_tde_ns1}"

pg2609_openbao_find_binary() {
  if [[ -n "${OPENBAO_BIN:-}" && -x "${OPENBAO_BIN}" ]]; then
    echo "${OPENBAO_BIN}"
    return 0
  fi
  local candidate
  for candidate in bao /usr/bin/bao /usr/local/bin/bao; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

pg2609_vault_token_value() {
  if [[ -n "${VAULT_TOKEN_FILE:-}" && -f "${VAULT_TOKEN_FILE}" ]]; then
    tr -d '[:space:]' < "${VAULT_TOKEN_FILE}"
    return 0
  fi
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    echo "${VAULT_TOKEN}"
    return 0
  fi
  return 1
}

pg2609_vault_reachable() {
  local addr="${1:-${VAULT_ADDR:-}}"
  local token
  [[ -n "${addr}" ]] || return 1
  token="$(pg2609_vault_token_value)" || return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS -m 5 -H "X-Vault-Token: ${token}" "${addr%/}/v1/sys/health" >/dev/null 2>&1
}

pg2609_kv_mount_ready() {
  local addr="${VAULT_ADDR:-}"
  local mount="${VAULT_SECRET_MOUNT:-${PG2609_OPENBAO_MOUNT}}"
  local ns="${VAULT_NAMESPACE:-}"
  local token code
  token="$(pg2609_vault_token_value)" || return 1
  [[ -n "${addr}" && -n "${ns}" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
    -H "X-Vault-Token: ${token}" \
    -H "X-Vault-Namespace: ${ns}" \
    -H "Content-Type: application/json" \
    -X POST "${addr%/}/v1/${mount}/data/pg2609_mount_probe" \
    -d '{"data":{"key":"dGVzdA=="}}')"
  [[ "${code}" == "200" || "${code}" == "204" ]]
}

pg2609_openbao_env_ready() {
  [[ -n "${VAULT_ADDR:-}" ]] \
    && pg2609_vault_token_value >/dev/null \
    && pg2609_vault_reachable "${VAULT_ADDR}" \
    && [[ -n "${VAULT_NAMESPACE:-}" ]] \
    && pg2609_kv_mount_ready
}

_pg2609_bao_root() {
  local bao="$1" token="$2" addr="$3"
  shift 3
  env -u VAULT_NAMESPACE VAULT_ADDR="${addr}" VAULT_TOKEN="${token}" \
    "${bao}" "$@"
}

_pg2609_bao_ns() {
  local bao="$1" token="$2" addr="$3" ns="$4"
  shift 4
  env -u VAULT_NAMESPACE \
    VAULT_ADDR="${addr}" VAULT_TOKEN="${token}" VAULT_NAMESPACE="${ns}" \
    "${bao}" "$@"
}

pg2609_bootstrap_namespace_mount() {
  local bao="$1"
  local root_token="$2"
  local ns="${3:-${PG2609_OPENBAO_NS}}"
  local mount="${4:-${PG2609_OPENBAO_MOUNT}}"
  local addr="${VAULT_ADDR:-${PG2609_OPENBAO_ADDR}}"
  local err_log="${5:-/tmp/PG-2609_openbao/bootstrap.err}"

  mkdir -p "$(dirname "${err_log}")"
  : > "${err_log}"

  if ! _pg2609_bao_root "${bao}" "${root_token}" "${addr}" namespace read "${ns}" \
    >/dev/null 2>&1; then
    if ! _pg2609_bao_root "${bao}" "${root_token}" "${addr}" namespace create "${ns}" \
      >>"${err_log}" 2>&1; then
      if ! _pg2609_bao_root "${bao}" "${root_token}" "${addr}" namespace list -format=json \
        2>>"${err_log}" | grep -q "\"${ns}/\""; then
        echo "ERROR: failed to create OpenBao namespace '${ns}'" >&2
        echo "  Hint: unset VAULT_NAMESPACE before bootstrap" >&2
        cat "${err_log}" >&2
        return 1
      fi
    fi
  fi

  if ! _pg2609_bao_ns "${bao}" "${root_token}" "${addr}" "${ns}" secrets list -format=json \
    2>>"${err_log}" | grep -q "\"${mount}/\""; then
    if ! _pg2609_bao_ns "${bao}" "${root_token}" "${addr}" "${ns}" \
      secrets enable -version=2 -path="${mount}" kv >>"${err_log}" 2>&1; then
      echo "ERROR: failed to enable KV v2 mount '${mount}' in namespace '${ns}'" >&2
      cat "${err_log}" >&2
      return 1
    fi
  fi

  export VAULT_ADDR="${addr}"
  export VAULT_SECRET_MOUNT="${mount}"
  export VAULT_NAMESPACE="${ns}/"

  if ! pg2609_kv_mount_ready; then
    echo "ERROR: KV mount '${mount}' not writable in namespace '${ns}/'" >&2
    cat "${err_log}" >&2
    return 1
  fi
  return 0
}

# Start local ``bao server -dev`` and prepare namespace + KV v2 mount.
pg2609_start_openbao() {
  local run_dir bao_bin bao_log root_token token_file deadline
  run_dir="${OPENBAO_RUN_DIR:-${REPRO_ROOT:-/tmp/PG-2609_openbao}/openbao}"
  mkdir -p "${run_dir}"

  bao_bin="$(pg2609_openbao_find_binary)" || {
    echo "ERROR: bao not found on PATH." >&2
    echo "  Install OpenBao, e.g.:" >&2
    echo "    cd postgresql/pytest && ./scripts/install_openbao.sh" >&2
    return 1
  }
  export OPENBAO_BIN="${bao_bin}"

  # Avoid stale shell namespace breaking ``bao namespace create``.
  unset VAULT_NAMESPACE

  if [[ "${OPENBAO_FORCE_RESTART:-0}" == "1" ]]; then
    pkill -f "[b]ao server" 2>/dev/null || true
    sleep 0.5
  fi

  bao_log="${run_dir}/bao_server.log"
  : > "${bao_log}"
  "${bao_bin}" server -dev -dev-listen-address=127.0.0.1:8200 >"${bao_log}" 2>&1 &
  OPENBAO_PID=$!
  export OPENBAO_PID

  root_token=""
  deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    if grep -q "Root Token:" "${bao_log}" 2>/dev/null; then
      root_token="$(grep -m1 "Root Token:" "${bao_log}" | awk '{print $3}')"
      break
    fi
    if ! kill -0 "${OPENBAO_PID}" 2>/dev/null; then
      echo "ERROR: bao server exited early. Log:" >&2
      cat "${bao_log}" >&2
      return 1
    fi
    sleep 0.3
  done

  if [[ -z "${root_token}" ]]; then
    echo "ERROR: could not read Root Token from ${bao_log}" >&2
    cat "${bao_log}" >&2
    return 1
  fi

  token_file="${run_dir}/bao_root_token"
  printf '%s\n' "${root_token}" > "${token_file}"
  chmod 600 "${token_file}"

  export VAULT_ADDR="${PG2609_OPENBAO_ADDR}"
  export VAULT_TOKEN_FILE="${token_file}"
  unset VAULT_TOKEN
  export VAULT_SECRET_MOUNT="${PG2609_OPENBAO_MOUNT}"
  export VAULT_NAMESPACE="${PG2609_OPENBAO_NS}/"

  if ! pg2609_bootstrap_namespace_mount \
    "${bao_bin}" "${root_token}" "${PG2609_OPENBAO_NS}" \
    "${PG2609_OPENBAO_MOUNT}" "${run_dir}/bootstrap.err"; then
    return 1
  fi

  echo "── OpenBao ready (inlined PG-2609 bootstrap) ──"
  echo "   bao=${bao_bin} pid=${OPENBAO_PID}"
  echo "   log=${bao_log}"
  echo "   VAULT_ADDR=${VAULT_ADDR}"
  echo "   namespace=${VAULT_NAMESPACE} mount=${VAULT_SECRET_MOUNT}"
  echo "   token_file=${VAULT_TOKEN_FILE}"
}

# Ensure Vault/OpenBao env is usable. Spawns local OpenBao when AUTO_OPENBAO=1.
pg2609_ensure_openbao() {
  local auto="${AUTO_OPENBAO:-1}"

  if [[ "${OPENBAO_FORCE_RESTART:-0}" != "1" ]] && pg2609_openbao_env_ready; then
    echo "── Reusing existing OpenBao/Vault env ──"
    echo "   VAULT_ADDR=${VAULT_ADDR}"
    echo "   namespace=${VAULT_NAMESPACE:-} mount=${VAULT_SECRET_MOUNT:-}"
    return 0
  fi

  if [[ "${auto}" != "1" ]]; then
    echo "ERROR: OpenBao/Vault not configured (VAULT_ADDR / token / mount)." >&2
    echo "  Set AUTO_OPENBAO=1 (default) to spawn local bao, or export VAULT_*." >&2
    return 1
  fi

  pg2609_start_openbao || return 1

  if ! pg2609_openbao_env_ready; then
    echo "ERROR: OpenBao KV mount not ready after bootstrap" >&2
    return 1
  fi
}
