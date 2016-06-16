#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Note: the many backticks used in this script are not SQL/MySQL column-surrounding backticks, but rather subshells which call a function, for example `table` calls table()

if [ "" == "$1" -o "$2" != "" ]; then
  echo "Please specify the number of queries to generate as the first (and only) option to this script"
  exit 1
else
  queries=$1
fi

RANDOM=`date +%s%N | cut -b13-19`

table(){ echo "$(shuf --random-source=/dev/urandom tables.txt | head -n1)"; }
pk()   { echo "$(shuf --random-source=/dev/urandom pk.txt     | head -n1)"; }
ctype(){ echo "$(shuf --random-source=/dev/urandom types.txt  | head -n1)"; }
data() { echo "$(shuf --random-source=/dev/urandom data.txt   | head -n1)"; }
onoff(){ echo "$(shuf --random-source=/dev/urandom onoff.txt  | head -n1)"; }
n10()  { echo "$(shuf --random-source=/dev/urandom 1-10.txt   | head -n1)"; }
n100() { echo "$(shuf --random-source=/dev/urandom 1-100.txt  | head -n1)"; }
n1000(){ echo "$(shuf --random-source=/dev/urandom 1-1000.txt | head -n1)"; }

create_table(){
  case $[$RANDOM % 3 + 1] in
    1)  echo "CREATE TABLE `table` (${C1} `pk`,${C2} `ctype`,${C3} `ctype`);" >> out.sql ;;
    2)  echo "CREATE TABLE `table` (${C1} `ctype`,${C2} `ctype`,${C3} `ctype`);" >> out.sql ;;
    3)  echo "CREATE TABLE `table` (${C1} `ctype`,${C2} `ctype`,${C3} `ctype`, PRIMARY KEY(${C1}(`n10`)));" >> out.sql ;;
    *)  echo "INVALID RANDOM SELECTION!!! ASSERT 1!!!"; exit ;;
  esac
}

if [ -r out.sql ]; then rm out.sql; fi
touch out.sql

for i in `eval echo {1..${queries}}`; do
  sort -R cols.txt | head -n3 >/tmp/cols.gen;C1=`cat /tmp/cols.gen | head -n1`;C2=`cat /tmp/cols.gen | head -n2 | tail -n1`;C3=`cat /tmp/cols.gen | tail -n1`;rm /tmp/cols.gen
  case $[$RANDOM % 10 + 1] in
    [1-4]) create_table ;; 
    5)  echo "DROP TABLE `table`;" >> out.sql ;;
    6)  echo "SELECT ${C1} FROM `table`;" >> out.sql ;;
    7)  echo "INSERT INTO `table` VALUES (`data`,`data`,`data`);" >> out.sql ;;
    8)  echo "DELETE FROM `table` LIMIT `n10`;" >> out.sql ;;
    9)  case $[$RANDOM % 5 + 1] in
          1)  echo "START TRANSACTION;" >> out.sql ;;
          [2-3]) echo "COMMIT;" >> out.sql ;;
          4)  echo "FLUSH TABLES;" >> out.sql ;;
          5)  echo "DROP TABLE `table`;" >> out.sql ;;
          *)  echo "INVALID RANDOM SELECTION!!! ASSERT 2!!!"; exit 1 ;;
        esac ;;
    10) create_table ;; 
    *)  echo "INVALID RANDOM SELECTION!!! ASSERT 3!!!"; exit 1 ;;
  esac
done

