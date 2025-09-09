#!/bin/bash

# Use repo=testing | release to test the packages on testing repo or release repo
repo=testing
pg_version=17.6
export REPO=$repo
export PG_VERSION=$pg_version

for os in debian11 debian12 ol8 ol9 ubuntu22 ubuntu24; do
    echo -e "\n=> Running tests on ${os^^}"
    pushd $os > /dev/null
    vagrant destroy -f
    vagrant up
    vagrant halt
    popd > /dev/null
    echo "=> Tests completed for $os"
done
