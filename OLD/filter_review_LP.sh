#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)

rm -Rf /tmp/toget
mkdir /tmp/toget
cd /tmp/toget
cat ${SCRIPT_PWD}/known_bugs.strings | grep -v "DONOTREMOVE" | grep "^[ \t]*[^#].*launchpad" | grep -o "http[^ ,]\+ " | sort -u | grep -v 'omment' | sed 's|^|wget |' > toget.sh
chmod +x toget.sh
./toget.sh
grep "+editstatus" * | grep "value status" | sed 's|.*+bug/||;s|/.*status| |;s|".*||' | sort -u
