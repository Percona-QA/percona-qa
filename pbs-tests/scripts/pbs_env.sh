#!/usr/bin/env bash
# Environment variables consumed by generate_config.py, all left empty.
#
# Usage:
#   1. Copy or edit this file and fill in the values you need; leave the
#      rest empty.
#   2. Source it (do NOT execute it -- exported variables only survive in
#      the shell that sources them):
#        source scripts/pbs_env.sh
#        . scripts/pbs_env.sh
#   3. Run scripts/generate_config.py. Any CLI flag you pass still
#      overrides the matching variable here, and anything left empty here
#      falls back to the script's own defaults (see --help).
#
# Security note: this file is meant to be a checked-in template with empty
# values. If you fill in a real MySQL password or S3 secret key, do not
# commit it. Prefer exporting secrets under your own variable name (e.g.
# MYSQL_REPL_PASSWORD) elsewhere and pointing the script at it with
# --password-env / --s3-secret-access-key-env instead of filling in
# MYSQL_PASSWORD / S3_SECRET_ACCESS_KEY directly below.

if ! (return 0 2>/dev/null); then
  echo "error: this file sets shell environment variables and must be sourced, not executed." >&2
  echo "run:  source ${BASH_SOURCE[0]:-$0}" >&2
  exit 1
fi

# --- logger ---
export LOG_LEVEL=              # --log-level (default: info)
export LOG_FILE=               # --log-file (default: console)

# --- connection (credentials) ---
export MYSQL_HOST=             # --host (mutually exclusive with MYSQL_DNS_SRV_NAME)
export MYSQL_PORT=             # --port (default: 3306)
export MYSQL_DNS_SRV_NAME=     # --dns-srv-name (mutually exclusive with MYSQL_HOST/MYSQL_PORT)
export MYSQL_USER=             # --user (default: root)
export MYSQL_PASSWORD=         # --password (see security note above)
export CONNECT_TIMEOUT=        # --connect-timeout (default: 20)
export READ_TIMEOUT=           # --read-timeout (default: 60)
export WRITE_TIMEOUT=          # --write-timeout (default: 60)

# --- connection.ssl (optional) ---
export SSL_MODE=               # --ssl-mode (disabled|preferred|required|verify_ca|verify_identity)
export SSL_CA=                 # --ssl-ca
export SSL_CAPATH=             # --ssl-capath
export SSL_CRL=                # --ssl-crl
export SSL_CRLPATH=            # --ssl-crlpath
export SSL_CERT=               # --ssl-cert
export SSL_KEY=                # --ssl-key
export SSL_CIPHER=             # --ssl-cipher

# --- connection.tls (optional) ---
export TLS_VERSION=            # --tls-version
export TLS_CIPHERSUITES=       # --tls-ciphersuites

# --- replication ---
export SERVER_ID=              # --server-id (default: 42)
export IDLE_TIME=              # --idle-time (default: 10)
export REPLICATION_MODE=       # --replication-mode (position|gtid, default: gtid)
export REWRITE_BASE_FILE_NAME= # --rewrite-base-file-name (requires gtid mode)
export REWRITE_FILE_SIZE=      # --rewrite-file-size, e.g. 128M (requires gtid mode)

# --- keyring (optional, needed to decrypt/encrypt binlogs) ---
export KEYRING_PATH=           # --keyring-path (local path; resolved to a file:// URI)

# --- storage ---
export STORAGE_BACKEND=        # --storage-backend (file|s3, default: file)
export STORAGE_PATH=           # --storage-path, local path for the file backend
export STORAGE_URI=            # --storage-uri, full URI for the s3 backend
export FS_BUFFER_DIRECTORY=    # --fs-buffer-directory
export CHECKPOINT_SIZE=        # --checkpoint-size, e.g. 2M
export CHECKPOINT_INTERVAL=    # --checkpoint-interval, e.g. 30s

# --- storage s3 helpers (build --storage-uri when STORAGE_BACKEND=s3) ---
export S3_ACCESS_KEY_ID=       # --s3-access-key-id
export S3_SECRET_ACCESS_KEY=   # --s3-secret-access-key (see security note above)
export S3_BUCKET=              # --s3-bucket
export S3_REGION=              # --s3-region
export S3_ENDPOINT=            # --s3-endpoint (set for S3-compatible endpoints; omit for AWS)
export S3_PATH=                # --s3-path, path/prefix inside the bucket

# --- storage.encryption (optional; or just pass --encryption for defaults) ---
export ENCRYPTION_KEK_ID=      # --encryption-kek-id (default when --encryption is passed: alpha)
export ENCRYPTION_CIPHER=      # --encryption-cipher (default when --encryption is passed: AES-256-CTR)
