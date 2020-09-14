#!/bin/bash

mv new-main-md.sql new-main-md.PREV 2>/dev/null  # Not .sql.PREV as then it will itself be re-included below!
if [ -r new-main-md.sql ]; then echo "Assert: new-main-md.sql exists, and should not"; exit 1; fi

echo "Compiling SQL from selected .sql files..."
echo "Currently selected files: mtr_to_sql*.sql, main*.sql, trx_and_flush.sql, then add optimizer.sql towards max rows (16777210)"
grep --binary-files=text -Evhi "SET.*[GS][LE][OS][BS][AI][LO].*=.*[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|SET.*[GS][LE][OS][BS][AI][LO].*=.*[0-9][6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|default_password_lifetime|SHUTDOWN|debug_dbug|SET PASSWORD" mtr_to_sql*.sql main*.sql > new-main-md.sql.tmp
for cnt in $(seq 1 20); do
  cat trx_and_flush.sql >> new-main-md.sql.tmp
done

CURRENT_LINES=$(wc -l new-main-md.sql.tmp 2>/dev/null | sed 's| .*||')
TOADD=$[ 16777210 - ${CURRENT_LINES} ]
echo "${CURRENT_LINES} in new-main-md.sql.tmp (max: 16777210, offset ${TOADD}) before finalization..."
head -n${TOADD} optimizer.sql >> new-main-md.sql.tmp

CURRENT_LINES=$(wc -l new-main-md.sql.tmp 2>/dev/null | sed 's| .*||')
echo "${CURRENT_LINES} in new-main-md.sql.tmp (max: 16777210) now. Now shuffling the file randomly..."
RANDOM=$(date +%s%N | cut -b10-19)
shuf --random-source=/dev/urandom new-main-md.sql.tmp > new-main-md.sql
rm -f new-main-md.sql.tmp

# Cleanup /tmp references
sed -i 's| /tmp/||g' new-main-md.sql
sed -i "s|'/tmp/|'|g" new-main-md.sql

CURRENT_LINES=$(wc -l new-main-md.sql 2>/dev/null | sed 's| .*||')
echo "${CURRENT_LINES} in new-main-md.sql (max: 16777210) now, and new-main-md.sql.tmp was removed..."
echo "Done!"
