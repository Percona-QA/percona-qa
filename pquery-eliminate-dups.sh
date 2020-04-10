#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script eliminates duplicate trials where at least x trials are present for a given issue, and x trials are kept for each such issue where duplicates are eliminated. Execute from within the pquery workdir. x is defined by the number of [0-9]\+, entries

# Internal variables
SCRIPT_PWD=$(cd `dirname $0` && pwd)

# Keep 10 Trials
# ${SCRIPT_PWD}/pquery-results.sh | grep -v 'TRIALS TO CHECK MANUALLY' | sed 's|_val||g' | grep -o "Seen[ \t]\+[0-9][0-9]\+ times.*" | sed 's|.*reduc||;s|ers [0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+,[0-9]\+||;s|)||;s|,|\n|g' | grep -v "^[ \t]*$" | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}

# Keep 3 Trials
${SCRIPT_PWD}/pquery-results.sh | grep -v 'TRIALS TO CHECK MANUALLY' | sed 's|_val||g' | grep -o "Seen[ \t]\+[0-9][0-9]\+ times.*" | sed 's|.*reduc||;s|ers [0-9]\+,[0-9]\+,[0-9]\+||;s|)||;s|,|\n|g' | grep -v "^[ \t]*$" | xargs -I{} ${SCRIPT_PWD}/pquery-del-trial.sh {}
