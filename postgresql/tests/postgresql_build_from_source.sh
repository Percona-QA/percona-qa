#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error
set -o pipefail  # Prevent errors in a pipeline from being masked

# Set variable
export BASE_DIR=/home/postgres
export INSTALL_DIR=/usr/local/ppg-17
export SRC_DIR=$BASE_DIR/postgres
export PATH=$INSTALL_DIR/bin:$PATH
export PGDATA=$INSTALL_DIR/data
export POSTGRESQL_CONF=$PGDATA/postgresql.conf
export LOG_FILE="build_log.log"

export POSTGRESQL_REPO="https://github.com/percona/postgres.git"
export POSTGRESQL_BRANCH="TDE_REL_17_STABLE"  # Change to a specific branch or tag if needed
export BUILD_DIR="build"
export JOBS=$(nproc)  # Number of parallel jobs for build

# Update and install required packages
sudo apt update -y
sudo apt install -y vim git curl wget

# Create and configure the postgres user
create_user() {
    if ! id -u postgres > /dev/null 2>&1; then
        sudo useradd -m postgres
    fi
        sudo usermod -aG sudo postgres
        sudo chsh -s /bin/bash postgres
        echo "postgres:test1" | sudo chpasswd
        echo "%postgres ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers
}


# Install development tools and dependencies
install_deps() {
    echo "Checking for required dependencies..."
    local dependencies=("make" "gcc" "libedit-dev" "zlib1g" "zlib1g-dev" "libicu-dev" "build-essential" "libreadline-dev" "zlib1g-dev" "flex" "bison" "libxml2-dev" "libxslt1-dev" "libssl-dev" "autoconf" "libcurl4-openssl-dev" "pkg-config" "libtest-simple-perl" "libipc-run-perl" "meson" "ninja" "python3" "perl" )
    for pkg in "${dependencies[@]}"; do
        if ! dpkg -l | grep -q $pkg; then
            echo "Installing $pkg..."
            sudo apt-get install -y $pkg
        fi
    done
    echo "All dependencies are installed. ✔️"
}

# Prepare PostgreSQL installation directory
create_postgres_dir() {
    sudo mkdir -p $PGDATA
    sudo chown postgres:postgres -R $INSTALL_DIR
}

# Clone and build PostgreSQL as the postgres user
clone_postgresql() {
    sudo -u postgres bash <<EOF
    cd $BASE_DIR
    git clone $POSTGRESQL_REPO
    cd $SRC_DIR
    git checkout $POSTGRESQL_BRANCH
    git pull
    git submodule update --init --recursive
    mkdir -p $BUILD_DIR
EOF

# meson $BUILD_DIR
# ninja -C $BUILD_DIR
# ninja -C $BUILD_DIR install
}

build_postgresql_make() {
    sudo -u postgres bash <<EOF
    cd $SRC_DIR
    ./configure --enable-debug --with-openssl --enable-cassert --enable-tap-tests --with-icu --prefix=$INSTALL_DIR
    make -j$JOBS
    make install
    cd $SRC_DIR/contrib/pg_tde/
    make
    make install
    cd ../..
    cd $SRC_DIR/contrib/pg_tde/
    make
    make install
    cd ../..
EOF
}

# initate the database
initialize_server() {
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/initdb -D $PGDATA
EOF
}

start_server() {
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA start -o "-p 5432" -l $PGDATA/logfile
EOF
}

stop_server() {
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA stop
EOF
}

restart_server() {
    sudo -u postgres bash <<EOF
    $INSTALL_DIR/bin/pg_ctl -D $PGDATA restart
EOF
}

set_path() {
    export PATH=$INSTALL_DIR/bin:$PATH
    export PGDATA=$PGDATA
}

# Create pg_tde_setup.sql file
create_pg_tde_key_file() {
    sudo -u postgres bash <<EOF
    cat > $BASE_DIR/pg_tde_setup.sql <<SQL
    CREATE EXTENSION IF NOT EXISTS pg_tde;
    SELECT pg_tde_add_key_provider_file('reg_file-vault', '/tmp/pg_tde_test_keyring.per');
    SELECT pg_tde_set_principal_key('test-db-principal-key', 'reg_file-vault');
    ALTER SYSTEM SET default_table_access_method='tde_heap';
    SET default_table_access_method='tde_heap';
    SELECT pg_reload_conf();
SQL
EOF
}

enable_pg_tde(){
    sudo -u postgres bash <<EOF
    if grep -q "^default_table_access_method" "$POSTGRESQL_CONF"; thP0+r\P0+r\P0+r\P0+r\P0+r\en
    sudo sed -i "s|^default_table_access_method.*|default_table_access_method = 'tde_heap'|" "$POSTGRESQL_CONF"
    else
    echo "default_table_access_method = 'tde_heap'" | sudo tee -a "$POSTGRESQL_CONF"
    fi
    $INSTALL_DIR/bin/psql -U postgres -c "ALTER SYSTEM SET shared_preload_libraries ='pg_tde';"
    $INSTALL_DIR/bin/psql -U postgres -c "ALTER SYSTEM SET pg_tde.wal_encrypt = on;"
EOF
restart_server
}

# Run the regression tests
run_tap_tests() {
    set_path
    create_pg_tde_key_file
    enable_pg_tde
    sudo -u postgres bash <<EOF
    cd $SRC_DIR
    EXTRA_REGRESS_OPTS="--extra-setup=$BASE_DIR/pg_tde_setup.sql --load-extension=pg_tde" make installcheck-world -k
EOF
}

# Main script execution
main() {
    echo "Starting PostgreSQL build process..."
    install_deps
    create_user
    create_postgres_dir
    clone_postgresql
    build_postgresql_make
    #build_postgresql_meson
    #install_postgresql
    initialize_server
    start_server
    run_tap_tests
    echo "PostgreSQL build process completed successfully! 🚀"
}

# Run the main function
main

