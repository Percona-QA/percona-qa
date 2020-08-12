#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

RANDOM_RUNS_PER_GRAMMAR=50
QUERIES_PER_GRAMMAR=50
DSN="dummy:print"
#DSN="dbi:mysql:host=127.0.0.1:port=14270:user=root:database=sakila"

if [ ! -r gensql.pl ]; then
  echo "Assert: we're not in a randgen directory, as ./gensql.pl was not found"
fi

rm -f /tmp/newsql.sql
touch /tmp/newsql.sql

for FILE in $(find . | grep "\.yy$"); do
  echo "Processing ${FILE}..."
  for LOOP in $(seq 0 ${RANDOM_RUNS_PER_GRAMMAR}); do
     RANDOM=$(date +%s%N | cut -b10-19)  # RANDOM: Random entropy pool init
     SEED=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
     MASK=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
     MASK_LEVEL=$(echo $[ $RANDOM % 3 ])
     if [ ${LOOP} -eq 0 ]; then  # Only show errors for the first run, much less screen filling
       ./gensql.pl --dsn=${DSN} --grammar=${FILE} --seed=${SEED} --queries=${QUERIES_PER_GRAMMAR} --mask-level=${MASK_LEVEL} --mask=${MASK} >> /tmp/newsql.sql
     else
       ./gensql.pl --dsn=${DSN} --grammar=${FILE} --seed=${SEED} --queries=${QUERIES_PER_GRAMMAR} --mask-level=${MASK_LEVEL} --mask=${MASK} >> /tmp/newsql.sql 2>/dev/null
     fi
  done
done
