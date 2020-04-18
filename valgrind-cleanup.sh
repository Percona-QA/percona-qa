#!/bin/bash
# Created by Roel Van de Paar Percona LLC
# Cleanups pquery trials from a Valgrind run, without deleting any trials that have cores files (use pquery-cleanup.sh for this)

# WIP. Atm, the script just outputs the files in which a Valgrind issue was found, and the first Valgrind issue in the file. Use with pquery-prep-red.sh and
# manually set MODE=1 (Valgrind testing) and TEXT="the string found, or a subsequent failure string from the error log reported by this script"

SCRIPT_PWD=$(cd "`dirname $0`" && pwd)

ls */log/master.err | xargs -I{} -i sh -c 'echo -n "{}:"; ${0}/valgrind_string.sh ./{}' ${SCRIPT_PWD} | grep -v "NO VALGRIND STRING FOUND"
