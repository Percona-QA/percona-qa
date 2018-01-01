#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script cleans all known issues in all subdirs (pquery-run.sh working directories)

ls -d [0-9][0-9][0-9][0-9][0-9][0-9] | \
 xargs -I{} sh -c 'cd {};~/percona-qa/pquery-clean-known.sh 1>/dev/null &'
