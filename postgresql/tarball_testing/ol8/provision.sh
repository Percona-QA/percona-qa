#!/bin/bash
set -e

username=postgres
server_version=17.5

# Create postgres user if not exists
if ! id "$username" &>/dev/null; then
    sudo useradd "$username" -m
fi

# Make sure base directory exists
sudo chmod o+rx /home/vagrant
mkdir pg_tarball
sudo chown $username:$username pg_tarball

# Oracle Linux 8 comes with OpenSSL 1.1.1 by default and requires OpenSSL 3.0 to be installed explicitly
current_openssl_version=$($(command -v openssl) version | awk '{print $2}')
echo "Current OpenSSL version: $current_openssl_version"
if [[ "$current_openssl_version" == 1.1.* ]]; then
    echo "Download OpenSSL 3.0 source"
    wget -q https://www.openssl.org/source/openssl-3.0.13.tar.gz
    tar -xzf openssl-3.0.13.tar.gz
    pushd openssl-3.0.13
    echo "Installing OpenSSL 3.0"
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

# ----------- FUNCTION DEFINITION -------------
run_tests() {
    local ssl_version=$1
    local workdir="pg_tarball/${ssl_version}"
    local tarball_name="percona-postgresql-${server_version}-${ssl_version}-linux-x86_64.tar.gz"
    local testing_repo_url="https://downloads.percona.com/downloads/TESTING/pg_tarballs-${server_version}/${tarball_name}"

    sudo -u "$username" -s /bin/bash <<EOF
set -e

if [ $ssl_version=ssl3 ]; then
  export LD_LIBRARY_PATH=/opt/openssl-3.0/lib64
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
./bin/psql -d postgres -c "CREATE EXTENSION pg_tde"
./bin/psql -d postgres -c "SELECT pg_tde_add_global_key_provider_file('global_file_provider','/tmp/keyring.per')"
./bin/psql -d postgres -c "SELECT pg_tde_add_database_key_provider_file('local_file_provider','/tmp/keyring.per')"
./bin/psql -d postgres -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_set_key_using_global_key_provider('database_key1', 'global_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_set_key_using_database_key_provider('database_key2', 'local_file_provider')"
./bin/psql -d postgres -c "SELECT pg_tde_set_default_key_using_global_key_provider('database_key3', 'global_file_provider')"

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
./bin/psql -d postgres -c "DROP EXTENSION pg_tde CASCADE"

EOF
}
# ----------- END FUNCTION -------------

# Run tests for both SSL versions
run_tests "ssl1.1"
run_tests "ssl3"
