#!/bin/bash
# Created by Roel Van de Paar, MariaDB

# This script cleans all specified issues in all subdirs (pquery-run.sh working directories)

if [ -z "${1}" ]; then echo "Assert: this script requires a string to be passed. Careful; this string will be matched against all trials in all subdirectories. If it is not long (and thus restrictive) enough, it will wipe a lot of trials!"; exit 1; fi

ls -d [0-9][0-9][0-9][0-9][0-9][0-9] | \
 xargs -I{} sh -c "cd {} 2>/dev/null; ~/pr | grep '${1}' | grep 'Seen' | sed 's|.*reducers ||;s|)||' | tr ',' '\n' | xargs -I{} ~/mariadb-qa/pquery-del-trial.sh {}"
