#!/bin/bash
set -e

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

echo "Using DNF for Oracle Linux $VERSION_ID"
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release enable-only ppg-$PG_VERSION $REPO
sudo dnf module disable postgresql -y
sudo dnf clean all
sudo dnf makecache
sudo dnf install -y percona-postgresql$PG_MAJOR-contrib percona-postgresql$PG_MAJOR-server percona-pg_tde$PG_MAJOR
# Initialize Datadir
sudo /usr/pgsql-$PG_MAJOR/bin/postgresql-$PG_MAJOR-setup initdb
# Start PG server
sudo systemctl start postgresql-$PG_MAJOR

# Add pg_tde extension in shared_preload_libraries in the PGCONF and restart server
sudo sed -i -E "s|^\s*#shared_preload_libraries\s*=\s*'[^']*'|shared_preload_libraries = 'pg_tde'|" /var/lib/pgsql/$PG_MAJOR/data/postgresql.conf
sudo systemctl restart postgresql-$PG_MAJOR

# Test pg_tde
rm -rf /tmp/keyring.per
sudo -u postgres psql <<EOF
SELECT version();
CREATE EXTENSION pg_tde;
SELECT pg_tde_add_global_key_provider_file('global_file_provider','/tmp/keyring.per');
SELECT pg_tde_add_database_key_provider_file('local_file_provider','/tmp/keyring.per');

SELECT pg_tde_create_key_using_global_key_provider('global_database_key', 'global_file_provider');
SELECT pg_tde_create_key_using_global_key_provider('server_key', 'global_file_provider');
SELECT pg_tde_create_key_using_global_key_provider('default_key', 'global_file_provider');
SELECT pg_tde_create_key_using_database_key_provider('database_key', 'local_file_provider');

SELECT pg_tde_set_key_using_database_key_provider('database_key', 'local_file_provider');
SELECT pg_tde_set_key_using_global_key_provider('global_database_key', 'global_file_provider');
SELECT pg_tde_set_server_key_using_global_key_provider('server_key', 'global_file_provider');
SELECT pg_tde_set_default_key_using_global_key_provider('default_key', 'global_file_provider');

CREATE TABLE t1(id INT, data TEXT) USING tde_heap;
INSERT INTO t1 VALUES (1, 'secret');
SELECT * FROM t1;
ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON';
EOF

# Enable WAL encryption
sudo systemctl restart postgresql-$PG_MAJOR

sudo -u postgres psql <<EOF
SELECT pg_tde_verify_key();
SELECT pg_tde_verify_server_key();
SELECT pg_tde_verify_default_key();
SELECT pg_tde_key_info();
SELECT pg_tde_server_key_info();
SELECT pg_tde_default_key_info();
SELECT * FROM t1;

SELECT pg_tde_is_encrypted('t1');
SHOW pg_tde.wal_encrypt;

SELECT pg_tde_delete_key();
DROP TABLE t1;
SELECT pg_tde_delete_default_key();

ALTER SYSTEM SET pg_tde.wal_encrypt = 'OFF';
EOF

# Disable WAL encryption
sudo systemctl restart postgresql-$PG_MAJOR

sudo -u postgres psql <<EOF
SHOW pg_tde.wal_encrypt;
DROP EXTENSION pg_tde;
EOF

# Stop server
sudo systemctl stop postgresql-$PG_MAJOR

# Uninstall PG package
sudo dnf remove -y percona-postgresql$PG_MAJOR-contrib percona-postgresql$PG_MAJOR-server
