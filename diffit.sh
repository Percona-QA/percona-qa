#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

echo "====== Diffs for first failure only"
echo "=== SQL"
FIRSTDIFFLINE=$(diff --unchanged-line-format="" --old-line-format="" --new-line-format="%dn|" $(ls *.result) | sed 's/|.*//')
DIFFLINEM1=$[ ${FIRSTDIFFLINE} -1 ]
sed "1,${DIFFLINEM1}d" $(ls *.result | head -n1) | head -n1
sed "1,${DIFFLINEM1}d" $(ls *.result | tail -n1) | head -n1

#cat ./pquery_thread-0.InnoDB.sql | head -n$(diff --unchanged-line-format="" --old-line-format="" --new-line-format="%dn" $(ls *.result) | tail -n1) | head -n1
echo "=== Diff"
diff --unchanged-line-format="" \
     --old-line-format="$(ls *.result | head -n1 | sed 's|.result||') Line %dn> %L" \
     --new-line-format="$(ls *.result | tail -n1 | sed 's|.result||') Line %dn> %L" $(ls *.result) \
     | head -n2
