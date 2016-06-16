#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Note: the many backticks used in this script are not SQL/MySQL column-surrounding backticks, but rather subshells which call a function, for example `table` calls table()
# To debug the SQL generated (it outputs the line numbers: "ERROR 1264 (22003) at line 47 in file" - so it easy to see which line (47 in example) failed in the SQL) use:
# echo '';echo '';./bin/mysql -A -uroot -S./socket.sock -e"SOURCE ~/percona-qa/pquery/generator/out.sql" --force test 2>&1 | grep "ERROR" | grep -vE "Unknown storage engine 'RocksDB'|Unknown storage engine 'TokuDB'|Table .* already exists|Table .* doesn't exist|Unknown table.*|Data truncated|doesn't support BLOB|Out of range value|Incorrect prefix key|Incorrect.*value|Data too long|Truncated incorrect.*value|Column.*cannot be null|Cannot get geometry object from data you send|doesn't support GEOMETRY"

if [ "" == "$1" -o "$2" != "" ]; then
  echo "Please specify the number of queries to generate as the first (and only) option to this script"
  exit 1
else
  queries=$1
fi

RANDOM=`date +%s%N | cut -b13-19`

# Read data files
mapfile -t tables  < tables.txt  ; TABLES=${#tables[*]}
mapfile -t pk      < pk.txt      ; PK=${#pk[*]}
mapfile -t types   < types.txt   ; TYPES=${#types[*]}
mapfile -t data    < data.txt    ; DATA=${#data[*]}
mapfile -t engines < engines.txt ; ENGINES=${#engines[*]}
mapfile -t onoff   < onoff.txt   ; ONOFF=${#onoff[*]}
mapfile -t n3      < 1-3.txt     ; N3=${#n3[*]}
mapfile -t n10     < 1-10.txt    ; N10=${#n10[*]}
mapfile -t n100    < 1-100.txt   ; N100=${#n100[*]}
mapfile -t n1000   < 1-1000.txt  ; N1000=${#n1000[*]}

table(){ echo "${tables[$[$RANDOM % $TABLES]]}"; }
pk()   { echo "${pk[$[$RANDOM % $PK]]}"; }
ctype(){ echo "${types[$[$RANDOM % $TYPES]]}"; }
data() { echo "${data[$[$RANDOM % $DATA]]}"; }
engin(){ echo "${engines[$[$RANDOM % $ENGINES]]}"; }
onoff(){ echo "${onoff[$[$RANDOM % $ONOFF]]}"; }
n3()   { echo "${n3[$[$RANDOM % $N3]]}"; }
n10()  { echo "${n10[$[$RANDOM % $N10]]}"; }
n100() { echo "${n100[$[$RANDOM % $N100]]}"; }
n1000(){ echo "${n1000[$[$RANDOM % $N1000]]}"; }

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
  case $[$RANDOM % 14 + 1] in
    [1-4]) create_table ;; 
    [5-6]) echo "DROP TABLE `table`;" >> out.sql ;;
    [7-9]) echo "INSERT INTO `table` VALUES (`data`,`data`,`data`);" >> out.sql ;;
    10) echo "SELECT c1 FROM `table`;" >> out.sql ;;
    11) echo "DELETE FROM `table` LIMIT `n10`;" >> out.sql ;;
    12) case $[$RANDOM % 5 + 1] in
          1) echo "UPDATE `table` SET c1=`data`;" >> out.sql ;;
          2) echo "UPDATE `table` SET c1=`data` LIMIT `n10`;" >> out.sql ;;
          3) echo "UPDATE `table` SET c1=`data` WHERE c2=`data`;" >> out.sql ;;
          4) echo "UPDATE `table` SET c1=`data` WHERE c2=`data` ORDER BY c3;" >> out.sql ;;
          5) echo "UPDATE `table` SET c1=`data` WHERE c2=`data` ORDER BY c3 LIMIT `n10`;" >> out.sql ;;
          *)  echo "Assert: invalid random case selection in UPDATE subcase"; exit 1 ;;
        esac ;;
    13) case $[$RANDOM % 5 + 1] in  # Generic statements
          [1-2]) echo "COMMIT;" >> out.sql ;;
          3)  echo "START TRANSACTION;" >> out.sql ;;
          4)  echo "FLUSH TABLES;" >> out.sql ;;
          5)  echo "DROP TABLE `table`;" >> out.sql ;;
          *)  echo "Assert: invalid random case selection in generic statements subcase"; exit 1 ;;
        esac ;;
    14) case $[$RANDOM % 21 + 1] in  # Alter
          1)  echo "ALTER TABLE `table` ADD COLUMN c4 `ctype`;" >> out.sql ;;
          2)  echo "ALTER TABLE `table` DROP COLUMN c1;" >> out.sql ;;
          3)  echo "ALTER TABLE `table` DROP COLUMN c2;" >> out.sql ;;
          4)  echo "ALTER TABLE `table` DROP COLUMN c3;" >> out.sql ;;
          5)  echo "ALTER TABLE `table` ENGINE=`engin`;" >> out.sql ;;
          6)  echo "ALTER TABLE `table` DROP PRIMARY KEY;" >> out.sql ;;
          7)  echo "ALTER TABLE `table` ADD INDEX (c1);" >> out.sql ;;
          8)  echo "ALTER TABLE `table` ADD INDEX (c2);" >> out.sql ;;
          9)  echo "ALTER TABLE `table` ADD INDEX (c3);" >> out.sql ;;
         10)  echo "ALTER TABLE `table` ADD UNIQUE (c1);" >> out.sql ;;
         11)  echo "ALTER TABLE `table` ADD UNIQUE (c2);" >> out.sql ;;
         12)  echo "ALTER TABLE `table` ADD UNIQUE (c3);" >> out.sql ;;
         13)  echo "ALTER TABLE `table` ADD INDEX (c1), ADD UNIQUE (c2);" >> out.sql ;;
         14)  echo "ALTER TABLE `table` ADD INDEX (c2), ADD UNIQUE (c3);" >> out.sql ;;
         15)  echo "ALTER TABLE `table` ADD INDEX (c3), ADD UNIQUE (c1);" >> out.sql ;;
         16)  echo "ALTER TABLE `table` MODIFY c1 `ctype` CHARACTER SET "Binary" COLLATE "Binary";" >> out.sql ;;
         17)  echo "ALTER TABLE `table` MODIFY c2 `ctype` CHARACTER SET "utf8" COLLATE "utf8_bin";" >> out.sql ;;
         18)  echo "ALTER TABLE `table` MODIFY c3 `ctype` CHARACTER SET "latin1" COLLATE "latin1_bin";" >> out.sql ;;
         19)  echo "ALTER TABLE `table` MODIFY c1 `ctype`;" >> out.sql ;;
         20)  echo "ALTER TABLE `table` MODIFY c2 `ctype`;" >> out.sql ;;
         21)  echo "ALTER TABLE `table` MODIFY c3 `ctype`;" >> out.sql ;;
          *)  echo "Assert: invalid random case selection in ALTER subcase"; exit 1 ;;
        esac ;;
     *) echo "Assert: invalid random case selection in main case"; exit 1 ;;
  esac
done

