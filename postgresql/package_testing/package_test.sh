#!/bin/bash

# Use REPO=testing | release to test the packages on testing repo or release repo
export REPO=release
export PG_VERSION=18.1
export PG_MAJOR=$(echo "$PG_VERSION" | cut -d. -f1)

for os in debian11 debian12 ol8 ol9 ubuntu22 ubuntu24; do
    echo -e "\n=> Running tests on ${os^^}"
    pushd $os > /dev/null
    vagrant destroy -f
    vagrant up
    vagrant halt
    popd > /dev/null
    echo "=> Tests completed for $os"
done
