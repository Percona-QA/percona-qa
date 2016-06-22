#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# User Variables
MYSQL_VERSION="56"  # Valid options: 56, 57

# Note: the many backticks used in this script are not SQL/MySQL column-surrounding backticks, but rather subshells which call a function, for example `table` calls table()
# To debug the SQL generated (it outputs the line numbers: "ERROR 1264 (22003) at line 47 in file" - so it easy to see which line (47 in example) failed in the SQL) use:
# echo '';echo '';./bin/mysql -A -uroot -S./socket.sock --force --binary-mode test < ~/percona-qa/pquery/generator/out.sql 2>&1 | grep "ERROR" | grep -vE "Unknown storage engine 'RocksDB'|Unknown storage engine 'TokuDB'|Table .* already exists|Table .* doesn't exist|Unknown table.*|Data truncated|doesn't support BLOB|Out of range value|Incorrect prefix key|Incorrect.*value|Data too long|Truncated incorrect.*value|Column.*cannot be null|Cannot get geometry object from data you send|doesn't support GEOMETRY|Cannot execute statement in a READ ONLY transaction"

if [ "" == "$1" -o "$2" != "" ]; then
  echo "Please specify the number of queries to generate as the first (and only) option to this script"
  exit 1
else
  queries=$1
fi

RANDOM=`date +%s%N | cut -b13-19`

# Check all needed data files are present
if [ ! -r tables.txt ]; then echo "Assert: tables.txt not found!"; exit 1; fi
if [ ! -r pk.txt ]; then echo "Assert: pk.txt not found!"; exit 1; fi
if [ ! -r types.txt ]; then echo "Assert: types.txt not found!"; exit 1; fi
if [ ! -r data.txt ]; then echo "Assert: data.txt not found!"; exit 1; fi
if [ ! -r engines.txt ]; then echo "Assert: engines.txt not found!"; exit 1; fi
if [ ! -r 1-3.txt ]; then echo "Assert: 1-3.txt not found!"; exit 1; fi
if [ ! -r 1-10.txt ]; then echo "Assert: 1-10.txt not found!"; exit 1; fi
if [ ! -r 1-100.txt ]; then echo "Assert: 1-100.txt not found!"; exit 1; fi
if [ ! -r 1-1000.txt ]; then echo "Assert: 1-1000.txt not found!"; exit 1; fi
if [ ! -r trx.txt ]; then echo "Assert: trx.txt not found!"; exit 1; fi
if [ ! -r flush.txt ]; then echo "Assert: flush.txt not found!"; exit 1; fi
if [ ! -r isolation.txt ]; then echo "Assert: isolation.txt not found!"; exit 1; fi
if [ ! -r lock.txt ]; then echo "Assert: lock.txt not found!"; exit 1; fi
if [ ! -r reset.txt ]; then echo "Assert: reset.txt not found!"; exit 1; fi
if [ ! -r setvar_session_$MYSQL_VERSION.txt ]; then echo "Assert: setvar_session_$MYSQL_VERSION.txt not found!"; exit 1; fi
if [ ! -r setvar_global_$MYSQL_VERSION.txt ]; then echo "Assert: setvar_global_$MYSQL_VERSION.txt not found!"; exit 1; fi
if [ ! -r setvalues.txt ]; then echo "Assert: setvalues.txt not found!"; exit 1; fi
if [ ! -r sqlmode.txt ]; then echo "Assert: sqlmode.txt not found!"; exit 1; fi
if [ ! -r optimizersw.txt ]; then echo "Assert: optimizersw.txt not found!"; exit 1; fi

# Read data files
mapfile -t tables    < tables.txt     ; TABLES=${#tables[*]}
mapfile -t pk        < pk.txt         ; PK=${#pk[*]}
mapfile -t types     < types.txt      ; TYPES=${#types[*]}
mapfile -t data      < data.txt       ; DATA=${#data[*]}
mapfile -t engines   < engines.txt    ; ENGINES=${#engines[*]}
mapfile -t n3        < 1-3.txt        ; N3=${#n3[*]}
mapfile -t n10       < 1-10.txt       ; N10=${#n10[*]}
mapfile -t n100      < 1-100.txt      ; N100=${#n100[*]}
mapfile -t n1000     < 1-1000.txt     ; N1000=${#n1000[*]}
mapfile -t trx       < trx.txt        ; TRX=${#trx[*]}
mapfile -t flush     < flush.txt      ; FLUSH=${#flush[*]}
mapfile -t isolation < isolation.txt  ; ISOL=${#isolation[*]}  # Excluses `COMMIT...RELEASE` SQL, as this drops CLI connection, though would be fine for pquery runs in principle
mapfile -t lock      < lock.txt       ; LOCK=${#lock[*]}
mapfile -t reset     < reset.txt      ; RESET=${#reset[*]}
mapfile -t setvarss  < setvar_session_$MYSQL_VERSION.txt; SETVARSS=${#setvars[*]}
mapfile -t setvarsg  < setvar_global_$MYSQL_VERSION.txt ; SETVARSG=${#setvarg[*]}
mapfile -t setvals   < setvalues.txt  ; SETVALUES=${#setvals[*]}
mapfile -t sqlmode   < sqlmode.txt    ; SQLMODE=${#sqlmode[*]}
mapfile -t optsw     < optimizersw.txt; OPTSW=${#optimizersw[*]}
   
table()  { echo "${tables[$[$RANDOM % $TABLES]]}"; }
pk()     { echo "${pk[$[$RANDOM % $PK]]}"; }
ctype()  { echo "${types[$[$RANDOM % $TYPES]]}"; }
data()   { echo "${data[$[$RANDOM % $DATA]]}"; }
engine() { echo "${engines[$[$RANDOM % $ENGINES]]}"; }
n3()     { echo "${n3[$[$RANDOM % $N3]]}"; }
n10()    { echo "${n10[$[$RANDOM % $N10]]}"; }
n100()   { echo "${n100[$[$RANDOM % $N100]]}"; }
n1000()  { echo "${n1000[$[$RANDOM % $N1000]]}"; }
trx()    { echo "${trx[$[$RANDOM % $TRX]]}"; }
flush()  { echo "${flush[$[$RANDOM % $FLUSH]]}"; }
isol()   { echo "${isolation[$[$RANDOM % $ISOL]]}"; }
lock()   { echo "${lock[$[$RANDOM % $LOCK]]}"; }
reset()  { echo "${reset[$[$RANDOM % $RESET]]}"; }
setvars(){ echo "${setvarss[$[$RANDOM % $SETVARS]]}"; }
setvarg(){ echo "${setvarsg[$[$RANDOM % $SETVARG]]}"; }
setval() { echo "${setvals[$[$RANDOM % $SETVALUES]]}"; }
sqlmode(){ echo "${sqlmode[$[$RANDOM % $SQLMODE]]}"; }
optsw()  { echo "${optsw[$[$RANDOM % $OPTSW]]}"; }
onoff()  { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "ON"; else echo "OFF"; fi }          # 75% ON, 25% OFF
globses(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi }  # 50% GLOBAL, 50% SESSION
temp()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "TEMPORARY "; else echo ""; fi }     # 20% TEMPORARY tables

if [ -r out.sql ]; then rm out.sql; fi
touch out.sql

for i in `eval echo {1..${queries}}`; do
  case $[$RANDOM % 17 + 1] in
    [1-4]) case $[$RANDOM % 3 + 1] in
        1) echo "CREATE `temp` TABLE `table` (c1 `pk`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`;" >> out.sql ;;
        2) echo "CREATE `temp` TABLE `table` (c1 `ctype`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`;" >> out.sql ;;
        3) C1TYPE=`ctype`
        if [ "`echo ${C1TYPE} | grep -o 'CHAR'`" == "CHAR" -o "`echo ${C1TYPE} | grep -o 'BLOB'`" == "BLOB" -o "`echo ${C1TYPE} | grep -o 'TEXT'`" == "TEXT" ]; then 
          echo "CREATE `temp` TABLE `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1(`n10`))) ENGINE=`engine`;" >> out.sql
        else
          echo "CREATE `temp` TABLE `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1)) ENGINE=`engine`;" >> out.sql
        fi;;
        *) echo "Assert: invalid random case selection in main create_table() case"; exit ;;
      esac ;;
    [5-6]) echo "DROP TABLE `table`;" >> out.sql ;;
    [7-9]) echo "INSERT INTO `table` VALUES (`data`,`data`,`data`);" >> out.sql ;;
    10) echo "SELECT c1 FROM `table`;" >> out.sql ;;
    11) echo "DELETE FROM `table` LIMIT `n10`;" >> out.sql ;;
    12) echo "TRUNCATE `table`;" >> out.sql ;;
    13) case $[$RANDOM % 5 + 1] in
        1) echo "UPDATE `table` SET c1=`data`;" >> out.sql ;;
        2) echo "UPDATE `table` SET c1=`data` LIMIT `n10`;" >> out.sql ;;
        3) echo "UPDATE `table` SET c1=`data` WHERE c2=`data`;" >> out.sql ;;
        4) echo "UPDATE `table` SET c1=`data` WHERE c2=`data` ORDER BY c3;" >> out.sql ;;
        5) echo "UPDATE `table` SET c1=`data` WHERE c2=`data` ORDER BY c3 LIMIT `n10`;" >> out.sql ;;
        *) echo "Assert: invalid random case selection in UPDATE subcase"; exit 1 ;;
      esac ;;
    1[4-6]) case $[$RANDOM % 21 + 1] in  # Generic statements
        [1-3]) echo "UNLOCK TABLES;" >> out.sql ;;
        [4-5]) echo "SET AUTOCOMMIT = ON;"  >> out.sql ;;
         6) echo "`flush`" | sed "s|DUMMY|`table`|;s|$|;|" >> out.sql ;;
         7) echo "`trx`" | sed "s|DUMMY|`table`|;s|$|;|" >> out.sql ;;
         8) echo "`reset`;" >> out.sql ;;
         9) echo "`isol`;" >> out.sql ;;
        1[0-2]) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`setval`|;s|$|;|" >> out.sql ;;  # The global/session vars also include sql_mode, which is like a 'reset'
        1[3-5]) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`setval`|;s|$|;|" >> out.sql ;;  # Note the servarS vs setvarG difference
         # Add or remove an SQL_MODE, with thanks http://johnemb.blogspot.com.au/2014/09/adding-or-removing-individual-sql-modes.html
        1[6-7]) echo "SET @@`globses`.SQL_MODE=(SELECT CONCAT(@@SQL_MODE,',`sqlmode`'));" >> out.sql ;;
        1[8-9]) echo "SET @@`globses`.SQL_MODE=(SELECT REPLACE(@@SQL_MODE,',`sqlmode`',''));" >> out.sql ;;
        2[0-1]) echo "SET @@`globses`.OPTIMIZER_SWITCH=\"`optsw`=`onoff`\";" >> out.sql ;;
         *) echo "Assert: invalid random case selection in generic statements subcase"; exit 1 ;;
      esac ;;
    17) case $[$RANDOM % 21 + 1] in  # Alter
         1) echo "ALTER TABLE `table` ADD COLUMN c4 `ctype`;" >> out.sql ;;
         2) echo "ALTER TABLE `table` DROP COLUMN c1;" >> out.sql ;;
         3) echo "ALTER TABLE `table` DROP COLUMN c2;" >> out.sql ;;
         4) echo "ALTER TABLE `table` DROP COLUMN c3;" >> out.sql ;;
         5) echo "ALTER TABLE `table` ENGINE=`engine`;" >> out.sql ;;
         6) echo "ALTER TABLE `table` DROP PRIMARY KEY;" >> out.sql ;;
         7) echo "ALTER TABLE `table` ADD INDEX (c1);" >> out.sql ;;
         8) echo "ALTER TABLE `table` ADD INDEX (c2);" >> out.sql ;;
         9) echo "ALTER TABLE `table` ADD INDEX (c3);" >> out.sql ;;
        10) echo "ALTER TABLE `table` ADD UNIQUE (c1);" >> out.sql ;;
        11) echo "ALTER TABLE `table` ADD UNIQUE (c2);" >> out.sql ;;
        12) echo "ALTER TABLE `table` ADD UNIQUE (c3);" >> out.sql ;;
        13) echo "ALTER TABLE `table` ADD INDEX (c1), ADD UNIQUE (c2);" >> out.sql ;;
        14) echo "ALTER TABLE `table` ADD INDEX (c2), ADD UNIQUE (c3);" >> out.sql ;;
        15) echo "ALTER TABLE `table` ADD INDEX (c3), ADD UNIQUE (c1);" >> out.sql ;;
        16) echo "ALTER TABLE `table` MODIFY c1 `ctype` CHARACTER SET "Binary" COLLATE "Binary";" >> out.sql ;;
        17) echo "ALTER TABLE `table` MODIFY c2 `ctype` CHARACTER SET "utf8" COLLATE "utf8_bin";" >> out.sql ;;
        18) echo "ALTER TABLE `table` MODIFY c3 `ctype` CHARACTER SET "latin1" COLLATE "latin1_bin";" >> out.sql ;;
        19) echo "ALTER TABLE `table` MODIFY c1 `ctype`;" >> out.sql ;;
        20) echo "ALTER TABLE `table` MODIFY c2 `ctype`;" >> out.sql ;;
        21) echo "ALTER TABLE `table` MODIFY c3 `ctype`;" >> out.sql ;;
         *) echo "Assert: invalid random case selection in ALTER subcase"; exit 1 ;;
       esac ;;
     *) echo "Assert: invalid random case selection in main case"; exit 1 ;;
  esac
done

sed -i "s|\t| |g" out.sql    # Replace tabs to spaces
sed -i "s|  \+| |g" out.sql  # Replace double or more spaces with single space
