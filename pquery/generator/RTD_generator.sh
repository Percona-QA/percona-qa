#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

if [ "" == "$1" ]; then
  echo "Please specify the number of queries to generate"
  exit 1
else
  queries=$1
fi

RANDOM=`date +%s%N | cut -b13-19`

if [ -r out.sql ]; then rm out.sql; fi
touch out.sql

for i in `eval echo {1..${queries}}`; do
  #COLS=`sort -R cols.txt | head -n3 > /tmp/cols.gen`;COL1=`cat /tmp/cols.gen | head -n1`;COL2=`cat /tmp/cols.gen | head -n2 | tail -n1`;COL3=`cat /tmp/cols.gen | tail -n1`
  case $[$RANDOM % 11 + 1] in
     1) echo "SET GLOBAL query_response_time_range_base=`sort -R 1-1000.txt | head -n1`;" >> out.sql ;;
     2) echo "SET GLOBAL query_response_time_stats=`sort -R ONOFF.txt | head -n1`;" >> out.sql ;;
     3) echo "SELECT COUNT(*) FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME_WRITE;" >> out.sql ;;
     4) echo "SELECT COUNT(*) FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME_READ;" >> out.sql ;;
     5) echo "SELECT COUNT(*) FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME;;" >> out.sql ;;
     6) echo "SELECT * FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME_WRITE;" >> out.sql ;;
     7) echo "SELECT * FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME_READ;" >> out.sql ;;
     8) echo "SELECT * FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME;" >> out.sql ;;
     9) echo "SHOW QUERY_RESPONSE_TIME;" >> out.sql ;;
    10) echo "FLUSH QUERY_RESPONSE_TIME;" >> out.sql ;;
    11) echo "SELECT c.count, c.time, (SELECT SUM(a.count) FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME as a WHERE a.count != 0) as query_count, (SELECT COUNT(*)     FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME as b WHERE b.count != 0) as not_zero_region_count, (SELECT COUNT(*)     FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME) as region_count FROM INFORMATION_SCHEMA.QUERY_RESPONSE_TIME as c WHERE c.count > 0;" >> out.sql ;;
    *) echo "INVALID RANDOM SELECTION!!! ASSERT 1!!!"; exit 1 ;;
  esac
done
#rm /tmp/cols.gen
