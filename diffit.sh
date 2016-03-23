#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

FIRSTDIFFLINE=$(diff --unchanged-line-format="" --old-line-format="" --new-line-format="%dn|" $(ls *.result) | sed 's/|.*//')
DIFFLINEM1=$[ ${FIRSTDIFFLINE} -1 ]

if [ "${FIRSTDIFFLINE}" == "" ]; then echo "No differences found between files $(ls *.result | tr '\n' ' ' | sed 's| | and |')!"; exit 1; fi

SQL1=$(echo -n "$(ls pquery_thread*.sql | tail -n1): "
       sed "1,${DIFFLINEM1}d" $(ls pquery_thread*.sql | tail -n1) | head -n1)
SQL2=$(echo -n "$(ls pquery_thread*.sql | head -n1): "
       sed "1,${DIFFLINEM1}d" $(ls pquery_thread*.sql | head -n1) | head -n1)

echo "${SQL1}"  | sed "s|\(.*\)sql:\(.*\)|\2 \[\1sql:${FIRSTDIFFLINE}\]|"
echo "${SQL2}"  | sed "s|\(.*\)sql:\(.*\)|\2 \[\1sql:${FIRSTDIFFLINE}\]|"
