#!/bin/bash
# Created by Roel Van de Paar, MariaDB

# This script cleans all specified issues in all subdirs (pquery-run.sh working directories)

ls -d [0-9][0-9][0-9][0-9][0-9][0-9] | \
 xargs -I{} sh -c "cd {} 2>/dev/null; ~/pr | grep '${1}' | grep 'Seen' | sed 's|.*reducers ||;s|)||' | tr ',' '\n' | xargs -I{} ~/mariadb-qa/pquery-del-trial.sh {}"
