#!/bin/bash

pg_version=18.1
export PG_VERSION=$pg_version

#for os in debian11 debian12 ol8 ol9 ubuntu20 ubuntu22 ubuntu24; do
for os in ol9 ; do
    echo -e "\n=> Running tests on ${os^^}"
    pushd $os > /dev/null
    vagrant destroy -f
    vagrant up
    vagrant halt
    popd > /dev/null
    echo "=> Tests completed for $os"
done
