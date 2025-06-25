#!/bin/bash
set -e

username=postgres
server_version=17.5

# Install required packages
sudo apt-get update
sudo apt-get install -y wget gnupg curl

# libreadline workaround for PG-1618
sudo apt-get install -y libreadline-dev

# Debian11 comes with OpenSSL1.1.1 by default and does not have OpenSSL3.0. To test tarballs built with ssl3
# we need to install OpenSSL 3.0 explicitly on Debian11
# Install dependencies
sudo apt-get install -y build-essential checkinstall zlib1g-dev

current_openssl_version=$($(command -v openssl) version | awk '{print $2}')
echo "Current OpenSSL version: $current_openssl_version"
if [[ "$current_openssl_version" == 1.1.* ]]; then
    echo "Download OpenSSL 3.0 source"
    wget -q https://www.openssl.org/source/openssl-3.0.13.tar.gz
    tar -xzf openssl-3.0.13.tar.gz
    pushd openssl-3.0.13
    echo "Installing OpenSSL 3.0"
    # Configure with custom install path (to avoid replacing system OpenSSL)
    ./Configure --prefix=/opt/openssl-3.0 --openssldir=/opt/openssl-3.0 shared zlib > /dev/null 2>&1
    # Build and install
    make -j$(nproc) > /dev/null 2>&1
    sudo make install > /dev/null 2>&1
    popd
elif [[ "$current_openssl_version" == 3.* ]]; then
    echo "Download OpenSSL 1.1.1 source"
    wget -q https://www.openssl.org/source/old/1.1.1/openssl-1.1.1w.tar.gz
    tar -xzf openssl-1.1.1w.tar.gz
    pushd openssl-1.1.1w
    echo "Installing OpenSSL 1.1.1"
    sudo ./Configure linux-x86_64 --prefix=/opt/openssl-1.1 --openssldir=/opt/openssl-1.1 shared zlib > /dev/null 2>&1
    # Build and install
    sudo make -j$(nproc) > /dev/null 2>&1
    sudo make install > /dev/null 2>&1
    popd
fi

# Create postgres user if not exists
if ! id "$username" &>/dev/null; then
  sudo useradd "$username" -m
fi

# Make sure base directory exists
mkdir pg_tarball
sudo chown $username:$username pg_tarball

# ----------- FUNCTION DEFINITION -------------
run_tests() {
  local ssl_version=$1
  local workdir="pg_tarball/${ssl_version}"
  local tarball_name="percona-postgresql-${server_version}-${ssl_version}-linux-x86_64.tar.gz"
  local testing_repo_url="https://downloads.percona.com/downloads/TESTING/pg_tarballs-${server_version}/${tarball_name}"

  sudo -u "$username" -s /bin/bash <<EOF
set -e

if [ $ssl_version == "ssl3" ]; then
  export LD_LIBRARY_PATH=/opt/openssl-3.0/lib64
elif [ $ssl_version == "ssl1.1" ]; then
  export LD_LIBRARY_PATH=/opt/openssl-1.1/lib
fi

mkdir "$workdir"
wget -q -P "$workdir" "$testing_repo_url"

cd "$workdir"
tar -xzf "$tarball_name"
cd percona-postgresql17

pkill -9 postgres || true
if [ -d data ]; then
  rm -rf data
fi

./bin/initdb -D data
sed -i "1i shared_preload_libraries = 'pg_tde'" data/postgresql.conf
./bin/pg_ctl -D data start

# pg_tde Tests
rm -rf /tmp/keyring.per
./bin/psql -d postgres -c "SELECT version()"
./bin/psql -d postgres -c "CREATE EXTENSION pg_tde"
./bin/psql -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_file_provider','/tmp/keyring.per')"
./bin/psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('local_file_provider','/tmp/keyring.per')"

./bin/psql -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('global_database_key', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('server_key', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_create_key_using_global_key_provider('default_key', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_create_key_using_database_key_provider('database_key', 'local_file_provider')"

./bin/psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('database_key', 'local_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('global_database_key', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('default_key', 'global_file_provider')"

./bin/psql -d postgres -c "CREATE TABLE t1(id INT, data TEXT) USING tde_heap"
./bin/psql -d postgres -c "INSERT INTO t1 VALUES (1, 'secret')"
./bin/psql -d postgres -c "SELECT * FROM t1"
./bin/psql -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'ON'"

./bin/pg_ctl -D data restart

./bin/psql -d postgres -c "SELECT pg_tde_verify_key()"
./bin/psql -d postgres -c "SELECT pg_tde_verify_server_key()"
./bin/psql -d postgres -c "SELECT pg_tde_verify_default_key()"
./bin/psql -d postgres -c "SELECT pg_tde_key_info()"
./bin/psql -d postgres -c "SELECT pg_tde_server_key_info()"
./bin/psql -d postgres -c "SELECT pg_tde_default_key_info()"
./bin/psql -d postgres -c "SELECT * FROM t1"

./bin/psql -d postgres -c "SELECT pg_tde_is_encrypted('t1')"
./bin/psql -d postgres -c "SHOW pg_tde.wal_encrypt"

./bin/psql -d postgres -c "SELECT pg_tde_delete_key()"
./bin/psql -d postgres -c "DROP TABLE t1"
./bin/psql -d postgres -c "SELECT pg_tde_delete_default_key()"

./bin/psql -d postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = 'OFF'"

./bin/pg_ctl -D data restart

./bin/psql -d postgres -c "SHOW pg_tde.wal_encrypt"
./bin/psql -d postgres -c "DROP EXTENSION pg_tde"

EOF
}
# ----------- END FUNCTION -------------

# Run tests for both SSL versions
run_tests "ssl1.1"
run_tests "ssl3"
