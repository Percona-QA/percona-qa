#!/bin/bash

DATA_DIR=$INSTALL_DIR/data
PORT=5432
KEYRING_FILE=/tmp/keyring.file
REPO_NAME=ppg-17.5
PACKAGE_NAME=percona-postgresql-17
DATADIR=/var/lib/postgresql/
PACKAGE_CONF_DIR=/etc/postgresql/17/main/
LOWER_VERSION=17.5.2
HIGHER_VERSION=17.5.3

install_postgresql_package() {
  echo "=> Enabling Percona repo: $REPO_NAME"
  sudo percona-release enable-only $REPO_NAME
  sudo apt-get update
  
  echo "=> Installing package: $PACKAGE_NAME"
  sudo apt-get install -y $PACKAGE_NAME > /dev/null

  if [ -d "$DATADIR" ]; then
    sudo pg_dropcluster --stop 17 main
    sudo rm -rf /var/lib/postgresql/17/main
  fi

  echo "=> Creating fresh cluster"
  sudo pg_createcluster 17 main --start
}

main_test() {

WAL_ENCRYPTION_BEFORE=$1
WAL_ENCRYPTION_FLIP=$2
WAL_ENCRYPTION_AFTER=$3

# Step 1: Kill any running PG server on port 5432
echo "=> Checking for running PostgreSQL on port $PORT"
PG_PID=$(sudo lsof -ti :$PORT || true)
if [ -n "$PG_PID" ]; then
  echo "=> Killing process $PG_PID"
  sudo kill -9 $PG_PID
fi

# Step 2: Remove keyring file
echo "=> Removing keyring file"
sudo rm -f "$KEYRING_FILE"

# Step 3: Cleanup old packages, conf, and data
echo "=> Removing old PG package"
sudo DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge $PACKAGE_NAME || true

sleep 2 

# Step 4: Install fresh package and start server
install_postgresql_package

sudo sed -i "/^shared_preload_libraries/s/percona_pg_telemetry/pg_tde,percona_pg_telemetry/" $PACKAGE_CONF_DIR/postgresql.conf
sudo systemctl restart postgresql@17-main

# Enable TDE
sudo -u postgres psql -p $PORT -c "CREATE EXTENSION pg_tde"
sudo -u postgres psql -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_file_provider1','$KEYRING_FILE')"
sudo -u postgres psql -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('server_key1', 'global_file_provider1')"
sudo -u postgres psql -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key1', 'global_file_provider1')"
sudo -u postgres psql -p $PORT -c "ALTER USER postgres WITH PASSWORD 'mypassword'"
sudo -u postgres psql -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt='$WAL_ENCRYPTION_BEFORE'"
sudo -u postgres psql -p $PORT -c "SHOW pg_tde.wal_encrypt"

sudo systemctl restart postgresql@17-main
sudo -u postgres psql -p $PORT -c "SHOW pg_tde.wal_encrypt"
if [ "$WAL_ENCRYPTION_FLIP" == "OFF" ]; then
  sudo -u postgres psql -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt='OFF'"
  sudo systemctl restart postgresql@17-main
  sudo -u postgres psql -p $PORT -c "SHOW pg_tde.wal_encrypt"
fi

echo "✅ PostgreSQL installation complete and server started on port $PORT"

sysbench /usr/share/sysbench/oltp_insert.lua \
  --pgsql-host=localhost \
  --pgsql-port=$PORT \
  --pgsql-user=postgres \
  --pgsql-password=mypassword \
  --pgsql-db=postgres \
  --db-driver=pgsql \
  --time=40 --threads=5 --tables=100 --table-size=1000 prepare

sleep 3

echo " Start the upgrade process..."
sudo systemctl stop postgresql@17-main

rm -rf $INSTALL_DIR/datadir_$LOWER_VERSION
sudo cp -R /var/lib/postgresql/17/main $INSTALL_DIR/datadir_$LOWER_VERSION
sudo cp $INSTALL_DIR/postgresql.conf $INSTALL_DIR/datadir_$LOWER_VERSION/postgresql.conf
sudo cp $INSTALL_DIR/pg_hba.conf $INSTALL_DIR/datadir_$LOWER_VERSION/pg_hba.conf

sudo chown -R mohit.joshi:percona $INSTALL_DIR/datadir_$LOWER_VERSION
sudo chown mohit.joshi:percona $KEYRING_FILE

echo "Starting PG server $HIGHER_VERSION using datadir_$LOWER_VERSION"
$INSTALL_DIR/bin/pg_ctl -D $INSTALL_DIR/datadir_$LOWER_VERSION start

$INSTALL_DIR/bin/psql -U postgres -p $PORT -c "CREATE EXTENSION pg_tde"
# Generate new keys and encrypt WALs
$INSTALL_DIR/bin/psql -U postgres -p $PORT -c "SELECT pg_tde_add_global_key_provider_file('global_file_provider2','$KEYRING_FILE')"
$INSTALL_DIR/bin/psql -U postgres -p $PORT -c "SELECT pg_tde_create_key_using_global_key_provider('server_key2', 'global_file_provider2')"
$INSTALL_DIR/bin/psql -U postgres -p $PORT -c "SELECT pg_tde_set_server_key_using_global_key_provider('server_key2', 'global_file_provider2')"
$INSTALL_DIR/bin/psql -U postgres -p $PORT -c "ALTER SYSTEM SET pg_tde.wal_encrypt='$WAL_ENCRYPTION_AFTER'"

echo "Restarting server"
$INSTALL_DIR/bin/pg_ctl -D $INSTALL_DIR/datadir_$LOWER_VERSION restart
$INSTALL_DIR/bin/psql -U postgres -p $PORT -c "SHOW pg_tde.wal_encrypt"

}


# Main test begins here
#
echo "# #################################################"
echo "# Scenario 1: Start server on 17.5.2              #"
echo "# WAL encryption OFF                              #"
echo "# Start PG 17.5.3 server using 17.5.2 datadir     #"
echo "# WAL encryption ON                               #"
echo "# #################################################"
main_test OFF OFF ON

echo " ##################################################"
echo "# Scenario 2: Start server on 17.5.2              #"
echo "# WAL encryption ON                               #"
echo "# WAL encryption OFF                              #"
echo "# Start PG 17.5.3 server using 17.5.2 datadir     #"
echo "# WAL encryption ON                               #"
echo "# #################################################"
main_test ON OFF ON
