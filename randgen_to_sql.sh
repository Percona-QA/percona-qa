#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ ! -r gensql.pl ]; then
  echo "Assert: we're not in a randgen directory, as ./gensql.pl was not found"
fi

if [ $(egrep "t1|c1" lib/GenTest/Generator/FromGrammar.pm | grep -v "prng" | wc -l) -ne 2 ]; then
  echo "Assert: required randgen patch is not in place, ref ./pquery/randgen_sql_generation.txt in percona-qa (i.e. this tree)"
fi

rm /tmp/newsql.sql

for FILE in $(find . | grep "\.yy$"); do
  echo "Processing ${FILE}..."
  for LOOP in $(seq 0 1000); do
     RANDOM=$(date +%s%N | cut -b14-19)  # RANDOM: Random entropy pool init. 
     SEED=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/')  # Random number generator (6 digits)
     ./gensql.pl --grammar=./conf/engines/blobs.yy --seed=${SEED} --queries=100 --mask-level=0 --mask=0 >> /tmp/newsql.sql
  done
done
