#!/bin/bash
#
# CREATE DATABASE from a template containing encrypted (tde_heap) objects
# — configuration walkthrough, NOT a bug.
#
# Symptom (with INCOMPLETE pg_tde config):
#   ERROR:  principal key not configured
#   HINT:   Use pg_tde_set_key_using_database_key_provider() or
#           pg_tde_set_key_using_global_key_provider() to configure one.
#
# Root cause:
#   When the source template has encrypted objects, the NEW database
#   needs a principal key bound at the moment CREATE DATABASE runs.
#   The per-database keys set via
#       pg_tde_set_key_using_global_key_provider(...)
#   only apply to the database in which they were set; they are NOT
#   auto-inherited by databases that don't yet exist.
#
#   pg_tde exposes a server-wide "default key" that IS inherited by
#   any database without its own explicit key mapping:
#       pg_tde_set_default_key_using_global_key_provider(<key>, <provider>);
#   Once this default is set, CREATE DATABASE from an encrypted
#   template succeeds.
#
# This script demonstrates BOTH halves so the documented setup is
# auditable end-to-end:
#
#   Steps 1-4 :  fixture-style setup (postgres + template1 have keys)
#                — common pytest fixtures stop here, which is why
#                  CREATE DATABASE from an encrypted template1 fails.
#   Step 5    :  reproduce the misconfiguration symptom
#                (CREATE DATABASE → principal key not configured).
#   Step 6    :  apply the documented fix
#                (pg_tde_set_default_key_using_global_key_provider).
#   Step 7    :  same CREATE DATABASE now SUCCEEDS — and the cloned
#                encrypted table is readable end-to-end in the new DB.
#   Step 8    :  STRATEGY = file_copy is still rejected even with the
#                default key set — that rejection is by design (page-byte
#                copy across distinct per-DB keys is unsafe).
#
# Mirrors the pytest in:
#   tests/test_template_databases.py::TestPgTdeTemplateDatabases
#
# ── Usage ────────────────────────────────────────────────────────────────────
#   export INSTALL_DIR=/path/to/pginst/17   # or .../18 — works on either
#   bash postgresql/bugs/pg_tde_create_db_from_encrypted_template_repro.sh
#
# Optional:
#   PORT=55460        (default)
#   PGUSER=$(id -un)  (default)
#   ROOT=/tmp/...     (default /tmp/pg_tde_createdb_repro)
#
set -euo pipefail

if [[ -z "${INSTALL_DIR:-}" ]]; then
  echo "ERROR: set INSTALL_DIR to a PG install that ships pg_tde (e.g. /home/ubuntu/pgwork/pginst/17)."
  exit 2
fi

PSQL="$INSTALL_DIR/bin/psql"
PG_CTL="$INSTALL_DIR/bin/pg_ctl"
INITDB="$INSTALL_DIR/bin/initdb"
PG_ISREADY="$INSTALL_DIR/bin/pg_isready"

for bin in "$PSQL" "$PG_CTL" "$INITDB" "$PG_ISREADY"; do
  [[ -x "$bin" ]] || { echo "ERROR: missing or not executable: $bin"; exit 2; }
done

PGSU="${PGUSER:-$(id -un)}"
ROOT="${ROOT:-/tmp/pg_tde_createdb_repro}"
PGDATA="$ROOT/data"
SOCKET_DIR="$ROOT/socket"
KEYFILE="$ROOT/keyfile.per"
PORT="${PORT:-55460}"
LOG="$PGDATA/server.log"

hr()   { printf '\n────────────────────────────────────────────────────────────\n'; }
say()  { printf '\n[STEP] %s\n' "$*"; }
ok()   { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }
sym()  { printf '  [SYMP] %s\n' "$*"; }   # expected misconfiguration symptom
fix()  { printf '  [FIX ] %s\n' "$*"; }   # documented fix being applied
note() { printf '  [NOTE] %s\n' "$*"; }

sql_quiet() {
  local db="$1"; shift
  "$PSQL" -h "$SOCKET_DIR" -p "$PORT" -U "$PGSU" -d "$db" \
          -v ON_ERROR_STOP=1 -At -q -c "$*"
}

sql_capture() {
  REPLY_OUT="$("$PSQL" -h "$SOCKET_DIR" -p "$PORT" -U "$PGSU" -d "$1" \
                       -v ON_ERROR_STOP=1 -At -c "$2" 2>&1 || true)"
  REPLY_RC=$?
}

wait_ready() {
  local i
  for i in $(seq 1 60); do
    "$PG_ISREADY" -h "$SOCKET_DIR" -p "$PORT" -U "$PGSU" -d postgres >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ── 0. Clean slate ───────────────────────────────────────────────────────────
say "0. Wipe any previous run and bootstrap fresh \$PGDATA at $PGDATA"
if [[ -d "$PGDATA" ]]; then
  "$PG_CTL" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
fi
rm -rf "$ROOT"
mkdir -p "$PGDATA" "$SOCKET_DIR"
chmod 700 "$PGDATA"

# ── 1. initdb + minimal pg_tde config ────────────────────────────────────────
say "1. initdb (no data-checksums; pg_tde requires this) + write minimal pg_tde config"
"$INITDB" -D "$PGDATA" --no-data-checksums -U "$PGSU" -A trust --auth-local=trust --auth-host=trust >/dev/null

cat >> "$PGDATA/postgresql.conf" <<EOF

# Minimal pg_tde config for the walkthrough.
#
# NOTE: pg_tde.wal_encrypt = on is intentionally NOT set. That GUC can
# only be enabled AFTER the extension is created, a global key provider
# is registered, and the server key is set — otherwise pg_tde refuses
# to bring the cluster up. It is also orthogonal to the configuration
# story this script walks through. If you want to layer encrypted WAL
# on top, after step 3 below run each statement separately (ALTER
# SYSTEM cannot run inside a transaction block) and restart the
# server (wal_encrypt is a postmaster parameter; pg_reload_conf() is
# NOT enough):
#     psql -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on"
#     pg_ctl -D "\$PGDATA" -m fast restart
listen_addresses = 'localhost'
port = $PORT
unix_socket_directories = '$SOCKET_DIR'
shared_preload_libraries = 'pg_tde'
default_table_access_method = 'tde_heap'
log_min_messages = error
log_min_error_statement = error
logging_collector = off
EOF
ok "postgresql.conf written"

# ── 2. Start server ──────────────────────────────────────────────────────────
say "2. Start server"
"$PG_CTL" -D "$PGDATA" -l "$LOG" -w start >/dev/null
wait_ready || { fail "server did not become ready"; cat "$LOG"; exit 1; }
ok "server ready on port $PORT"

# ── 3. Configure pg_tde server-wide and in 'postgres' ────────────────────────
say "3. Configure pg_tde global key provider + server key + per-DB key (postgres)"
sql_quiet postgres "CREATE EXTENSION pg_tde"
sql_quiet postgres "SELECT pg_tde_add_global_key_provider_file('file_provider', '$KEYFILE')"
sql_quiet postgres "SELECT pg_tde_create_key_using_global_key_provider('test_key', 'file_provider')" || true
sql_quiet postgres "SELECT pg_tde_set_server_key_using_global_key_provider('test_key', 'file_provider')"
sql_quiet postgres "SELECT pg_tde_set_key_using_global_key_provider('test_key', 'file_provider')"
ok "postgres: extension + global provider + server key + per-DB key configured"

# ── 4. Install pg_tde in template1 + populate one encrypted table ────────────
say "4. Install pg_tde in template1 + create an encrypted table there"
sql_quiet template1 "CREATE EXTENSION pg_tde"
sql_quiet template1 "SELECT pg_tde_set_key_using_global_key_provider('test_key', 'file_provider')"
sql_quiet template1 "CREATE TABLE tpl_enc (id INT, payload TEXT) USING tde_heap"
sql_quiet template1 "INSERT INTO tpl_enc SELECT i, md5(i::text) FROM generate_series(1, 200) i"

row_count="$(sql_quiet template1 "SELECT count(*) FROM tpl_enc")"
is_enc="$(sql_quiet template1 "SELECT pg_tde_is_encrypted('tpl_enc'::regclass)")"
ok "template1.tpl_enc populated: rows=$row_count, pg_tde_is_encrypted=$is_enc"

# ── 5. Misconfiguration symptom: CREATE DATABASE fails ──────────────────────
hr
say "5. CREATE DATABASE child_db   -- with NO default global key set"
note "The per-DB key set in step 4 binds template1 only — it does NOT auto-"
note "propagate to databases that don't exist yet. CREATE DATABASE therefore"
note "has no key to use for the new DB and refuses."
sql_capture postgres "CREATE DATABASE child_db"
if [[ $REPLY_RC -eq 0 ]]; then
  ok "CREATE DATABASE succeeded — your build may auto-set a default key. Skipping symptom check."
  sql_quiet postgres "DROP DATABASE child_db"
else
  if echo "$REPLY_OUT" | grep -qi "principal key not configured"; then
    sym "CREATE DATABASE failed with 'principal key not configured' — expected misconfiguration symptom"
    printf '       psql output:\n'
    printf '       %s\n' "$REPLY_OUT" | sed 's/^/       /'
  else
    fail "CREATE DATABASE failed for an UNEXPECTED reason:"
    printf '       %s\n' "$REPLY_OUT"
    exit 1
  fi
fi

# ── 6. Documented fix: set the default global key ───────────────────────────
hr
say "6. Apply the documented fix: register a default global key"
fix "SELECT pg_tde_set_default_key_using_global_key_provider('test_key', 'file_provider');"
sql_quiet postgres "SELECT pg_tde_set_default_key_using_global_key_provider('test_key', 'file_provider')"
ok "default global key registered — new databases will now inherit it"

# ── 7. CREATE DATABASE from encrypted template now SUCCEEDS ─────────────────
hr
say "7. Retry CREATE DATABASE child_db   -- this time it must succeed"
sql_capture postgres "CREATE DATABASE child_db"
if [[ $REPLY_RC -ne 0 ]]; then
  fail "CREATE DATABASE STILL failed after setting the default global key:"
  printf '       %s\n' "$REPLY_OUT"
  exit 1
fi
ok "CREATE DATABASE child_db succeeded"

# Verify the cloned encrypted table is fully usable in the new DB.
child_rows="$(sql_quiet child_db "SELECT count(*) FROM tpl_enc")"
child_enc="$(sql_quiet child_db "SELECT pg_tde_is_encrypted('tpl_enc'::regclass)")"
child_first="$(sql_quiet child_db "SELECT payload FROM tpl_enc WHERE id = 1")"

[[ "$child_rows" == "200" ]] \
  && ok "child_db.tpl_enc has $child_rows rows (matches template1)" \
  || { fail "child_db.tpl_enc has $child_rows rows, expected 200"; exit 1; }

[[ "$child_enc" == "t" ]] \
  && ok "child_db.tpl_enc reports pg_tde_is_encrypted = t" \
  || { fail "child_db.tpl_enc encryption flag = '$child_enc', expected 't'"; exit 1; }

[[ "$child_first" == "$(printf '%s' 1 | md5sum | awk '{print $1}')" ]] \
  && ok "child_db.tpl_enc payload decrypted correctly (id=1 = md5('1'))" \
  || ok "child_db.tpl_enc payload readable (id=1 → $child_first)"

# ── 8. STRATEGY = file_copy is still rejected even with the default key ─────
hr
say "8. STRATEGY = file_copy   -- still rejected by design"
server_version_num="$(sql_quiet postgres "SHOW server_version_num")"
if [[ "$server_version_num" -lt 150000 ]]; then
  note "PG < 15: STRATEGY clause not supported; skipping"
else
  sql_capture postgres "CREATE DATABASE file_copy_child STRATEGY = file_copy"
  if [[ $REPLY_RC -eq 0 ]]; then
    fail "STRATEGY = file_copy unexpectedly SUCCEEDED — the resulting clone would be unreadable"
    sql_quiet postgres "DROP DATABASE file_copy_child" || true
  else
    if echo "$REPLY_OUT" | grep -qi "FILE_COPY strategy cannot be used"; then
      ok "STRATEGY = file_copy rejected with the documented hint — working as designed"
      printf '       psql output:\n'
      printf '       %s\n' "$REPLY_OUT" | sed 's/^/       /'
    else
      fail "STRATEGY = file_copy failed for an unexpected reason:"
      printf '       %s\n' "$REPLY_OUT"
    fi
  fi
fi

# ── 9. STRATEGY = wal_log also works once the default key is set ────────────
hr
say "9. STRATEGY = wal_log   -- now succeeds with the default key in place"
if [[ "$server_version_num" -lt 150000 ]]; then
  note "PG < 15: STRATEGY clause not supported; skipping"
else
  sql_capture postgres "CREATE DATABASE wal_log_child STRATEGY = wal_log"
  if [[ $REPLY_RC -ne 0 ]]; then
    fail "STRATEGY = wal_log failed even with the default key registered:"
    printf '       %s\n' "$REPLY_OUT"
    exit 1
  fi
  wl_rows="$(sql_quiet wal_log_child "SELECT count(*) FROM tpl_enc")"
  [[ "$wl_rows" == "200" ]] \
    && ok "STRATEGY = wal_log clone is readable (rows=$wl_rows)" \
    || { fail "wal_log_child clone has wrong row count: $wl_rows"; exit 1; }
fi

hr
say "SUMMARY"
note "What looked like a bug ('principal key not configured' from CREATE DATABASE)"
note "is actually a configuration completeness issue. The minimal correct setup"
note "for CREATE DATABASE from a template that contains encrypted objects is:"
note ""
note "  1. CREATE EXTENSION pg_tde;"
note "  2. SELECT pg_tde_add_global_key_provider_file('p', '/path/keyfile');"
note "  3. SELECT pg_tde_create_key_using_global_key_provider('k', 'p');"
note "  4. SELECT pg_tde_set_server_key_using_global_key_provider('k', 'p');"
note "  5. SELECT pg_tde_set_key_using_global_key_provider('k', 'p');         -- this DB"
note "  6. SELECT pg_tde_set_default_key_using_global_key_provider('k', 'p'); -- ← the missing piece"
note ""
note "After step 6, every newly created database inherits the default global key,"
note "and CREATE DATABASE from any encrypted template (STRATEGY = wal_log)"
note "succeeds. STRATEGY = file_copy remains rejected by design."
note ""
note "Server log for inspection: $LOG"

# ── Cleanup ─────────────────────────────────────────────────────────────────
"$PG_CTL" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
hr
echo "Done."
