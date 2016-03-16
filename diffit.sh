#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

echo "=== SQL (first failure only)"
cat ./pquery_thread-0.InnoDB.sql | head -n$(diff --unchanged-line-format="" --old-line-format="" --new-line-format="%dn" $(ls *.result) | tail -n1) | head -n1
echo "=== Diff (first failure only)"
diff --unchanged-line-format="" \
     --old-line-format="$(ls *.result | head -n1 | sed 's|.result||') Line %dn> %L" \
     --new-line-format="$(ls *.result | tail -n1 | sed 's|.result||') Line %dn> %L" $(ls *.result) \
     | head -n2
