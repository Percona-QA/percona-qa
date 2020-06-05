#!/bin/bash

mv new-main-md.sql new-main-md.PREV 2>/dev/null  # Not .sql.PREV as then it will itself be re-included below!
if [ -r new-main-md.sql ]; then echo "Assert: new-main-md.sql exists, and should not"; exit 1; fi

echo "Compiling SQL from all .sql files..."
grep --binary-files=text -Evhi "SET.*[GS][LE][OS][BS][AI][LO].*=.*[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|SET.*[GS][LE][OS][BS][AI][LO].*=.*[0-9][6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|default_password_lifetime|SHUTDOWN|debug_dbug|SET PASSWORD" *.sql > new-main-md.sql.tmp

CURRENT_LINES=$(wc -l new-main-md.sql.tmp 2>/dev/null | sed 's| .*||')
TOADD=$[ 16777210 - ${CURRENT_LINES} ]
echo "${CURRENT_LINES} in new-main-md.sql.tmp (max: 16777210, offset ${TOADD}) before finalization..."
head -n${TOADD} optimizer.sql >> new-main-md.sql.tmp

CURRENT_LINES=$(wc -l new-main-md.sql.tmp 2>/dev/null | sed 's| .*||')
echo "${CURRENT_LINES} in new-main-md.sql.tmp (max: 16777210) now. Now shuffling the file randomly..."
RANDOM=$(date +%s%N | cut -b14-19)
shuf --random-source=/dev/urandom new-main-md.sql.tmp > new-main-md.sql
rm -f new-main-md.sql.tmp

CURRENT_LINES=$(wc -l new-main-md.sql 2>/dev/null | sed 's| .*||')
echo "${CURRENT_LINES} in new-main-md.sql (max: 16777210) now, and new-main-md.sql.tmp was removed..."
echo "Done!"
