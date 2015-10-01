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
  COLS=`sort -R cols.txt | head -n3 > /tmp/cols.gen`;COL1=`cat /tmp/cols.gen | head -n1`;COL2=`cat /tmp/cols.gen | head -n2 | tail -n1`;COL3=`cat /tmp/cols.gen | tail -n1`
  case $[$RANDOM % 5 + 1] in
    1) case $[$RANDOM % 3 + 1] in
         1) echo "CREATE TABLE `sort -R tables.txt | head -n1` ($COL1 `sort -R pk.txt | head -n1`,$COL2 `sort -R types.txt | head -n1`,$COL3 `sort -R types.txt | head -n1`);" >> out.sql ;;
         2) echo "CREATE TABLE `sort -R tables.txt | head -n1` ($COL1 `sort -R types.txt | head -n1`,$COL2 `sort -R types.txt | head -n1`,$COL3 `sort -R types.txt | head -n1`);" >> out.sql ;;
         3) echo "CREATE TABLE `sort -R tables.txt | head -n1` ($COL1 `sort -R types.txt | head -n1`,$COL2 `sort -R types.txt | head -n1`,$COL3 `sort -R types.txt | head -n1`, PRIMARY KEY($COL1(`sort -R 1-10.txt | head -n1`)));" >> out.sql ;;
         *) echo "INVALID RANDOM SELECTION!!! ASSERT 1!!!"; exit ;;
       esac ;;
    2) echo "SELECT `sort -R cols.txt | head -n1` FROM `sort -R tables.txt | head -n1`;" >> out.sql ;;
    3) echo "INSERT INTO `sort -R tables.txt | head -n1` VALUES (`sort -R data.txt | head -n1`,`sort -R data.txt | head -n1`,`sort -R data.txt | head -n1`);" >> out.sql ;;
    4) echo "DELETE FROM `sort -R tables.txt | head -n1` LIMIT `sort -R 1-10.txt | head -n1`;" >> out.sql ;;
    5) case $[$RANDOM % 4 + 1] in
         1) echo "START TRANSACTION;" >> out.sql ;;
         2) echo "COMMIT;" >> out.sql ;;
         3) echo "FLUSH TABLES;" >> out.sql ;;
         4) echo "DROP TABLE `sort -R tables.txt | head -n1`;" >> out.sql ;;
         *) echo "INVALID RANDOM SELECTION!!! ASSERT 2!!!"; exit 1 ;;
       esac ;;
    *) echo "INVALID RANDOM SELECTION!!! ASSERT 3!!!"; exit 1 ;;
  esac
done
rm /tmp/cols.gen
