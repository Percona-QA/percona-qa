#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Note: the many backticks used in this script are not SQL/MySQL column-surrounding backticks, but rather subshells which call a function, for example `table` calls table()
# To debug the SQL generated (it outputs the line numbers: "ERROR 1264 (22003) at line 47 in file" - so it easy to see which line (47 in example) failed in the SQL) use:
# echo '';echo '';./bin/mysql -A -uroot -S./socket.sock -e"SOURCE ~/percona-qa/pquery/generator/out.sql" --force test 2>&1 | grep "ERROR" | grep -vE "Unknown storage engine 'RocksDB'|Unknown storage engine 'TokuDB'|Table .* already exists|Table .* doesn't exist|Unknown table.*|Data truncated|doesn't support BLOB"
# Or, a bit more restrictive (may miss some issues):
# echo '';echo '';./bin/mysql -A -uroot -S./socket.sock -e"SOURCE ~/percona-qa/pquery/generator/out.sql" --force test 2>&1 | grep "ERROR" | grep -vE "Unknown storage engine 'RocksDB'|Unknown storage engine 'TokuDB'|Table .* already exists|Table .* doesn't exist|Unknown table.*|Data truncated|doesn't support BLOB|Out of range value|Incorrect prefix key|Incorrect.*value|Data too long"

if [ "" == "$1" -o "$2" != "" ]; then
  echo "Please specify the number of queries to generate as the first (and only) option to this script"
  exit 1
else
  queries=$1
fi

RANDOM=`date +%s%N | cut -b13-19`

table(){ echo "$(shuf --random-source=/dev/urandom tables.txt  | head -n1)"; }
pk()   { echo "$(shuf --random-source=/dev/urandom pk.txt      | head -n1)"; }
ctype(){ echo "$(shuf --random-source=/dev/urandom types.txt   | head -n1)"; }
data() { echo "$(shuf --random-source=/dev/urandom data.txt    | head -n1)"; }
engin(){ echo "$(shuf --random-source=/dev/urandom engines.txt | head -n1)"; }
onoff(){ echo "$(shuf --random-source=/dev/urandom onoff.txt   | head -n1)"; }
n10()  { echo "$(shuf --random-source=/dev/urandom 1-10.txt    | head -n1)"; }
n100() { echo "$(shuf --random-source=/dev/urandom 1-100.txt   | head -n1)"; }
n1000(){ echo "$(shuf --random-source=/dev/urandom 1-1000.txt  | head -n1)"; }

create_table(){
  case $[$RANDOM % 3 + 1] in
    1)  echo "CREATE TABLE `table` (c1 `pk`,c2 `ctype`,c3 `ctype`) ENGINE=`engin`;" >> out.sql ;;
    2)  echo "CREATE TABLE `table` (c1 `ctype`,c2 `ctype`,c3 `ctype`) ENGINE=`engin`;" >> out.sql ;;
    3)  C1TYPE=`ctype`
        if [ "`echo ${C1TYPE} | grep -o 'CHAR'`" == "CHAR" -o "`echo ${C1TYPE} | grep -o 'BLOB'`" == "BLOB" -o "`echo ${C1TYPE} | grep -o 'TEXT'`" == "TEXT" ]; then 
          echo "CREATE TABLE `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1(`n10`))) ENGINE=`engin`;" >> out.sql
        else
          echo "CREATE TABLE `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1)) ENGINE=`engin`;" >> out.sql
        fi;;
    *)  echo "Assert: invalid random case selection in main create_table() case"; exit ;;
  esac
}

if [ -r out.sql ]; then rm out.sql; fi
touch out.sql

for i in `eval echo {1..${queries}}`; do
  case $[$RANDOM % 10 + 1] in
    [1-4]) create_table ;; 
    [5-6]) echo "DROP TABLE `table`;" >> out.sql ;;
    7)  echo "SELECT c1 FROM `table`;" >> out.sql ;;
    8)  echo "INSERT INTO `table` VALUES (`data`,`data`,`data`);" >> out.sql ;;
    9)  echo "DELETE FROM `table` LIMIT `n10`;" >> out.sql ;;
    10) case $[$RANDOM % 5 + 1] in
          1) echo "UPDATE `table` SET c1=`data`;" >> out.sql ;;
          2) echo "UPDATE `table` SET c1=`data` LIMIT `n10`;" >> out.sql ;;
          3) echo "UPDATE `table` SET c1=`data` WHERE c2=`data`;" >> out.sql ;;
          4) echo "UPDATE `table` SET c1=`data` WHERE c2=`data` ORDER BY c3;" >> out.sql ;;
          5) echo "UPDATE `table` SET c1=`data` WHERE c2=`data` ORDER BY c3 LIMIT `n10`;" >> out.sql ;;
          *)  echo "Assert: invalid random case selection in UPDATE subcase"; exit 1 ;;
        esac ;;
    11) case $[$RANDOM % 5 + 1] in  # Generic statements
          [1-2]) echo "COMMIT;" >> out.sql ;;
          3)  echo "START TRANSACTION;" >> out.sql ;;
          4)  echo "FLUSH TABLES;" >> out.sql ;;
          5)  echo "DROP TABLE `table`;" >> out.sql ;;
          *)  echo "Assert: invalid random case selection in generic statements subcase"; exit 1 ;;
        esac ;;
    *)  echo "Assert: invalid random case selection in main case"; exit 1 ;;
  esac
done

