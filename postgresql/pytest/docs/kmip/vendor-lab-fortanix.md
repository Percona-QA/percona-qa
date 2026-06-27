# Fortanix DSM lab setup — pg_tde KMIP on Fortanix

> **Documentation index:** [README.md](README.md)

This guide walks through configuring **Fortanix Data Security Manager (DSM)** for
**Percona PostgreSQL with pg_tde** KMIP key providers in the Percona QA lab.

The Fortanix UI flow follows the same pattern as the official Percona MySQL
integration guide:

- [Fortanix DSM for Percona MySQL Encryption at Rest](https://support.fortanix.com/docs/fortanix-dsm-for-percona-mysql-encryption-at-rest)
- [Percona pg_tde — Fortanix](https://docs.percona.com/pg-tde/global-key-provider-configuration/fortanix.html)

MySQL uses `component_keyring_kmip`; pg_tde uses SQL functions such as
`pg_tde_add_global_key_provider_kmip`. The **Fortanix app, group, client
certificate, and KMIP endpoint** are the same.

---

## Regional DSM URLs

Fortanix SaaS is region-specific. Pick the URL closest to your lab:

| Region | Web UI | KMIP host (port 5696) | API (automation) |
|--------|--------|------------------------|------------------|
| Americas | [https://amer.smartkey.io](https://amer.smartkey.io) | `amer.smartkey.io` | `https://api.amer.smartkey.io` |
| APAC | [https://apac.smartkey.io](https://apac.smartkey.io) | `apac.smartkey.io` | `https://api.apac.smartkey.io` |
| Europe | [https://eu.smartkey.io](https://eu.smartkey.io) | `eu.smartkey.io` | `https://api.eu.smartkey.io` |

Use the **same regional hostname** for pg_tde, pytest, and TLS tests. Do not mix
regions (for example, an app created in APAC will not work against `amer.smartkey.io`).

See also the [Fortanix DSM SaaS global availability map](https://support.fortanix.com/hc/en-us/articles/4406135346068-Fortanix-DSM-SaaS-Global-Availability-Map).

---

## Prerequisites

- Ubuntu (or similar) VM with network access to Fortanix KMIP port **5696**
- **pg_tde** built or installed for your PostgreSQL major version
- `openssl`, `nc`, and Python 3.9+ (for pytest)
- Percona QA repo cloned:

```bash
git clone https://github.com/percona/percona-qa.git
cd percona-qa/postgresql/pytest
```

---

## Part 1 — Fortanix DSM (web UI)

### 1.1 Sign up for a trial account

1. Open **[https://amer.smartkey.io](https://amer.smartkey.io)** in a browser.
   (Use `apac.smartkey.io` or `eu.smartkey.io` if your lab is in another region.)
2. Create a **free 30-day trial** account on **Data Security Manager — Enterprise Tier**.
3. Complete email verification and log in.

### 1.2 Create a group

Groups control which security objects an app can access.

1. In the left navigation panel, click **Groups**.
2. Click **ADD GROUP**.
3. On **Adding new group**:
   - **Title**: any descriptive name, for example `TestingPgTDE`
   - **Description** (optional): e.g. `Percona pg_tde KMIP lab`
4. Click **SAVE**.

### 1.3 Create an application (app)

1. Click **Apps** in the left panel.
2. Click **ADD APP**.
3. On **Adding new app**:
   - **App name**: e.g. `PerconaPgTDE` or `Percona QA pg_tde 2026`
   - **Description** (optional)
   - **Authentication method**: leave **API Key** for now (you will switch to **Certificate** after generating certs)
   - **Assigning the new app to groups**: select the group from step 1.2 (`TestingPgTDE`)
4. Click **SAVE**.

### 1.4 Copy the app UUID

The client certificate **Common Name (CN)** must equal the app UUID.

1. Open the app you just created.
2. At the top of the app page, click the **copy** icon next to **UUID**.
3. Save it — you need it when generating the client certificate.

Example UUID: `2fc7ce2a-6700-4e41-b6cf-fc3ecc6c4fc0`

---

## Part 2 — Client certificate and Fortanix auth

Fortanix KMIP uses **mutual TLS**. pg_tde presents a client certificate whose
**CN is the app UUID**. This matches
[section 2.6 of the Fortanix Percona MySQL guide](https://support.fortanix.com/docs/fortanix-dsm-for-percona-mysql-encryption-at-rest#26-generating-the-certificate).

### 2.1 Generate client key and certificate

On your lab VM:

```bash
export CERT_DIR=~/fortanix_kmip_certs
export APP_UUID="<paste-app-uuid-here>"

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

openssl req -newkey rsa:2048 -nodes \
  -keyout client_key.pem \
  -x509 -days 365 \
  -out client_certificate.pem \
  -subj "/CN=${APP_UUID}"
```

Verify the subject:

```bash
openssl x509 -in client_certificate.pem -noout -subject
# subject=CN = 2fc7ce2a-6700-4e41-b6cf-fc3ecc6c4fc0
```

### 2.2 Switch app authentication to Certificate

1. Open the app in the Fortanix UI.
2. Click **Change authentication method**.
3. Select **Certificate**.
4. Click **SAVE**.
5. In **Add certificate**, either:
   - **UPLOAD NEW CERTIFICATE** → select `client_certificate.pem`, or
   - Paste the PEM contents of `client_certificate.pem`
6. Confirm both checkboxes and click **UPDATE**.

---

## Part 3 — Server CA and TLS verification

KMIP listens on port **5696**. The server certificate chains to a **public CA**
(Sectigo). Your `server_ca` file must allow OpenSSL to complete that chain.

### 3.1 Check KMIP connectivity

```bash
export CERT_DIR=~/fortanix_kmip_certs
export KMIP_HOST=amer.smartkey.io   # match your region

nc -zv "$KMIP_HOST" 5696
```

### 3.2 Build `dsm_ca.crt` (recommended)

On Ubuntu, append the system trust store to your CA file:

```bash
# Start from an empty or intermediate-only file, then append public roots
cp /etc/ssl/certs/ca-certificates.crt "$CERT_DIR/dsm_ca.crt"

# Or append to an existing intermediate bundle:
# cat /etc/ssl/certs/ca-certificates.crt >> "$CERT_DIR/dsm_ca.crt"
```

Alternative: use the system bundle directly as `server_ca`:

```bash
cp /etc/ssl/certs/ca-certificates.crt "$CERT_DIR/server_ca.crt"
```

### 3.3 Verify mutual TLS

```bash
openssl s_client -connect "${KMIP_HOST}:5696" \
  -cert "$CERT_DIR/client_certificate.pem" \
  -key  "$CERT_DIR/client_key.pem" \
  -CAfile "$CERT_DIR/dsm_ca.crt" </dev/null 2>&1 | grep -i "Verify return code"
```

Expected:

```text
Verify return code: 0 (ok)
```

If you see `Verify return code: 2 (unable to get issuer certificate)`, the CA
file is incomplete — use `/etc/ssl/certs/ca-certificates.crt` as shown above.
Do **not** rely only on the HTTPS (443) certificate chain from the browser; KMIP
on 5696 may present a different leaf.

---

## Part 4 — Register pg_tde KMIP providers

Set your PostgreSQL install path and connect to your running instance:

```bash
export INSTALL_DIR=/home/ubuntu/pgwork/pginst/18   # adjust
export CERT_DIR=~/fortanix_kmip_certs
export KMIP_HOST=amer.smartkey.io                 # match your region
```

### 4.1 Global key provider

```bash
$INSTALL_DIR/bin/psql -d postgres -p 5433 -c "
SELECT pg_tde_add_global_key_provider_kmip(
  'fortanix_ring',
  '${KMIP_HOST}',
  5696,
  '${CERT_DIR}/client_certificate.pem',
  '${CERT_DIR}/client_key.pem',
  '${CERT_DIR}/dsm_ca.crt'
);"
```

### 4.2 Create and activate a global key

```bash
$INSTALL_DIR/bin/psql -d postgres -p 5433 -c "
SELECT pg_tde_create_key_using_global_key_provider('test_key_1', 'fortanix_ring');
SELECT pg_tde_set_key_using_global_key_provider('test_key_1', 'fortanix_ring');
"
```

Use **`pg_tde_set_key_using_global_key_provider`** for a **global** provider.
`pg_tde_set_key_using_database_key_provider` requires a **database-scoped** provider
(see step 4.3).

### 4.3 Database-scoped provider (optional)

```bash
$INSTALL_DIR/bin/psql -d postgres -p 5433 -c "
SELECT pg_tde_add_database_key_provider_kmip(
  'fortanix_db_ring',
  '${KMIP_HOST}',
  5696,
  '${CERT_DIR}/client_certificate.pem',
  '${CERT_DIR}/client_key.pem',
  '${CERT_DIR}/dsm_ca.crt'
);

SELECT pg_tde_create_key_using_database_key_provider('test_key_db', 'fortanix_db_ring');
SELECT pg_tde_set_key_using_database_key_provider('test_key_db', 'fortanix_db_ring');
"
```

### 4.4 Encrypted table smoke test

```bash
$INSTALL_DIR/bin/psql -d postgres -p 5433 -c "
CREATE TABLE fortanix_smoke(id int) USING tde_heap;
INSERT INTO fortanix_smoke VALUES (1);
SELECT * FROM fortanix_smoke;
"
```

Check **Security Objects** and **Activity logs** in the Fortanix UI to confirm
key registration and KMIP operations.

---

## Part 5 — Run pytest KMIP tests against Fortanix

Pytest creates **temporary PostgreSQL clusters**; it does not use your manual
`5433` instance. It only needs `INSTALL_DIR` (binaries + pg_tde extension) and
Fortanix env vars.

### 5.1 One-time pytest environment

```bash
cd percona-qa/postgresql/pytest
bash setup_test_env.sh --install-dir "$INSTALL_DIR"
source .env.sh
```

### 5.2 Fortanix profile env file

```bash
cat > ~/fortanix_kmip_pytest.env <<EOF
export KMIP_PROFILE=fortanix
export KMIP_REVALIDATE_PROFILES=fortanix

export KMIP_FORTANIX_HOST=${KMIP_HOST}
export KMIP_FORTANIX_PORT=5696
export KMIP_FORTANIX_CLIENT_CERT=${CERT_DIR}/client_certificate.pem
export KMIP_FORTANIX_CLIENT_KEY=${CERT_DIR}/client_key.pem
export KMIP_FORTANIX_SERVER_CA=${CERT_DIR}/dsm_ca.crt
EOF

source ~/fortanix_kmip_pytest.env
```

### 5.3 Run tests

**Vendor matrix (recommended sign-off):**

```bash
cd percona-qa/postgresql/pytest
source .env.sh
source ~/fortanix_kmip_pytest.env

./scripts/run_kmip_matrix.sh
```

**Extended suite + PG-2125 regression:**

```bash
KMIP_PROFILE=fortanix pytest tests/test_kmip.py -v

KMIP_PROFILE=fortanix pytest \
  tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression -v
```

**Full Fortanix run in one command:**

```bash
./scripts/run_kmip_matrix.sh && \
KMIP_PROFILE=fortanix pytest tests/test_kmip.py -v && \
KMIP_PROFILE=fortanix pytest \
  tests/test_external_key_provider_regressions.py::TestKmipCppClientRegression -v
```

See also [test-catalog.md](test-catalog.md) and
[../key_provider_matrix.md](../key_provider_matrix.md).

---

## Part 6 — Optional: automated setup script

The repo root contains `fortanix_kmip_setup.py`, which can create the group, app,
client certificate, and certificate auth via the Fortanix API (MySQL team pattern).

```bash
cd percona-qa

python3 fortanix_kmip_setup.py \
  --email 'you@example.com' \
  --password 'your-password' \
  --dsm-url https://amer.smartkey.io \
  --api-url https://api.amer.smartkey.io \
  --app-name PerconaPgTDE \
  --group-name TestingPgTDE \
  --cert-dir ~/fortanix_kmip_certs \
  -v
```

After the script runs, still build `dsm_ca.crt` from the system trust store
(section 3.2) and verify TLS on port 5696 before pg_tde or pytest.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Verify return code: 2` | Incomplete `dsm_ca.crt` | Use `/etc/ssl/certs/ca-certificates.crt` |
| `key provider "X" does not exist` on `set_key_using_database_key_provider` | Global vs database scope mismatch | Use `set_key_using_global_key_provider`, or add `add_database_key_provider_kmip` first |
| KMIP connect timeout | Wrong region hostname or firewall | `nc -zv <host> 5696`; match app region |
| pg_tde add provider fails TLS | Wrong cert paths or CN ≠ app UUID | Re-check `openssl x509 -noout -subject` |
| pytest tests skipped | Env not sourced | `source ~/fortanix_kmip_pytest.env` |
| Register key errors in Fortanix UI | App not in group or cert auth not enabled | Re-do sections 1.2–2.2 |

---

## File layout (lab VM)

```text
~/fortanix_kmip_certs/
├── client_certificate.pem   # CN = app UUID
├── client_key.pem
├── dsm_ca.crt               # trust store for KMIP server (5696)
└── server_ca.crt            # optional copy of ca-certificates.crt

~/fortanix_kmip_pytest.env   # pytest KMIP_FORTANIX_* exports
```

---

## References

- [Fortanix DSM for Percona MySQL Encryption at Rest](https://support.fortanix.com/docs/fortanix-dsm-for-percona-mysql-encryption-at-rest)
- [Percona pg_tde — Fortanix global key provider](https://docs.percona.com/pg-tde/global-key-provider-configuration/fortanix.html)
- [Percona pg_tde KMIP functions](https://docs.percona.com/pg-tde/functions.html)
- Percona QA: [quickstart.md](quickstart.md), [vendor-signoff.md](vendor-signoff.md)
