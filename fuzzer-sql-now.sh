#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Internal variables - do not modify
SCRIPT_PWD=$(cd "`dirname $0`" && pwd)
BASEDIR=$(grep -m1 "BASEDIR" ${SCRIPT_PWD}/fuzzer-run.sh | sed 's|[ \t]*#.*||;s|BASEDIR=||')

for file in $(ls ${BASEDIR}/out/fuzzer*/.cur_input); do echo "====== $file"; cat $file; echo ""; done
