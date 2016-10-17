#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script eliminates duplicate trials where at least 10 trials are present for a given issue, and 10 trials are kept for each such issue where duplicates are eliminated. Execute from within the pquery workdir.

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

${SCRIPT_PWD}/pquery-results.sh | sed 's|_val||g' | grep -o "Seen[ \t]\+[0-9][0-9]\+ times.*" | sed 's|.*reducers ||;s|[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+||;s|)||;s|,|\n|g' | grep -v "^[ \t]*$" | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}
