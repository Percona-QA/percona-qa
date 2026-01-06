#!/bin/bash
set -e

#Set the installation directory and source directories
SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
INSTALL_DIR="$SCRIPT_DIR/../pginst"
PSP_SOURCE_DIR="$SCRIPT_DIR/../psp_repo"
TDE_SOURCE_DIR="$SCRIPT_DIR/../tde_repo"
PSP_REPO="https://github.com/percona/postgres.git"
TDE_REPO="https://github.com/percona/pg_tde.git"
PSP_BRANCH="PSP_REL_18_STABLE"
TDE_BRANCH="main"

#Clean up the installation directory and source directories
rm -fr "$INSTALL_DIR"
rm -fr "$PSP_SOURCE_DIR"
rm -fr "$TDE_SOURCE_DIR"

#Clone the source repositories
git clone "$PSP_REPO" "$PSP_SOURCE_DIR" -b "$PSP_BRANCH"
git clone "$TDE_REPO" "$TDE_SOURCE_DIR" -b "$TDE_BRANCH"

cd "$PSP_SOURCE_DIR"

#Configure the build
./configure \
    --prefix="$INSTALL_DIR" \
    --enable-debug \
    --enable-tap-tests \
    --with-liburing \
    --enable-cassert \
    --with-icu

#Create the installation directory
mkdir -p "$INSTALL_DIR"

#Build the server
make install-world -j -s
make install -j -s -C src/test/modules/injection_points

#Copy the pg_config to the system path
sudo cp $INSTALL_DIR/bin/pg_config /usr/bin

#Build the TDE 
cd "$TDE_SOURCE_DIR"

#Initialize the submodules
git submodule update --init --recursive

#Set the environment path for the TDE build
export PATH="$INSTALL_DIR/bin:$INSTALL_DIR/lib:$PATH"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$LD_LIBRARY_PATH"
echo "--------------------------------\n"
echo "PATH: $PATH"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "--------------------------------\n"

#Build the TDE
make PG_CONFIG="$INSTALL_DIR/bin/pg_config"
echo "--------------------------------\n"

#Build the TDE
sudo make PG_CONFIG="$INSTALL_DIR/bin/pg_config" install -j -s
