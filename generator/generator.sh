#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# User Variables
MYSQL_VERSION="57"  # Valid options: 56, 57. Do not use dot (.)

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
if [ ! -r lock.txt ]; then echo "Assert: lock.txt not found!"; exit 1; fi
if [ ! -r reset.txt ]; then echo "Assert: reset.txt not found!"; exit 1; fi
if [ ! -r session_$MYSQL_VERSION.txt ]; then echo "Assert: session_$MYSQL_VERSION.txt not found!"; exit 1; fi
if [ ! -r global_$MYSQL_VERSION.txt ]; then echo "Assert: global_$MYSQL_VERSION.txt not found!"; exit 1; fi
if [ ! -r setvalues.txt ]; then echo "Assert: setvalues.txt not found!"; exit 1; fi
if [ ! -r sqlmode.txt ]; then echo "Assert: sqlmode.txt not found!"; exit 1; fi
if [ ! -r optimizersw.txt ]; then echo "Assert: optimizersw.txt not found!"; exit 1; fi
if [ ! -r inmetrics.txt ]; then echo "Assert: inmetrics.txt not found!"; exit 1; fi

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
mapfile -t lock      < lock.txt       ; LOCK=${#lock[*]}
mapfile -t reset     < reset.txt      ; RESET=${#reset[*]}
mapfile -t setvars   < session_$MYSQL_VERSION.txt; SETVARS=${#setvars[*]}
mapfile -t setvarg   < global_$MYSQL_VERSION.txt ; SETVARG=${#setvarg[*]}
mapfile -t setvals   < setvalues.txt  ; SETVALUES=${#setvals[*]}
mapfile -t sqlmode   < sqlmode.txt    ; SQLMODE=${#sqlmode[*]}
mapfile -t optsw     < optimizersw.txt; OPTSW=${#optsw[*]}
mapfile -t inmetrics < inmetrics.txt  ; INMETRICS=${#inmetrics[*]}

if [ ${TABLES} -lt 2 ]; then echo "Assert: number of tables less then 2. A minimum of two tables is required for proper operation. Please ensure tables.txt has at least two tables"; exit 1; fi
   
# ========================================= From File
table()    { echo "${tables[$[$RANDOM % $TABLES]]}"; }
pk()       { echo "${pk[$[$RANDOM % $PK]]}"; }
ctype()    { echo "${types[$[$RANDOM % $TYPES]]}"; }
data()     { echo "${data[$[$RANDOM % $DATA]]}"; }
engine()   { echo "${engines[$[$RANDOM % $ENGINES]]}"; }
n3()       { echo "${n3[$[$RANDOM % $N3]]}"; }
n10()      { echo "${n10[$[$RANDOM % $N10]]}"; }
n100()     { echo "${n100[$[$RANDOM % $N100]]}"; }
n1000()    { echo "${n1000[$[$RANDOM % $N1000]]}"; }
trx()      { echo "${trx[$[$RANDOM % $TRX]]}"; }
flush()    { echo "${flush[$[$RANDOM % $FLUSH]]}"; }
lock()     { echo "${lock[$[$RANDOM % $LOCK]]}"; }
reset()    { echo "${reset[$[$RANDOM % $RESET]]}"; }
setvars()  { echo "${setvars[$[$RANDOM % $SETVARS]]}"; }
setvarg()  { echo "${setvarg[$[$RANDOM % $SETVARG]]}"; }
setval()   { echo "${setvals[$[$RANDOM % $SETVALUES]]}"; }
sqlmode()  { echo "${sqlmode[$[$RANDOM % $SQLMODE]]}"; }
optsw()    { echo "${optsw[$[$RANDOM % $OPTSW]]}"; }
inmetrics(){ echo "${inmetrics[$[$RANDOM % $INMETRICS]]}"; }
# ========================================= Single, random
n2()       { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "1"; else echo "2"; fi }             # 50% 1, 50% 2
temp()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "TEMPORARY "; fi }                   # 20% TEMPORARY
ignore()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "IGNORE"; fi }                       # 20% IGNORE
lowprio()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "LOW_PRIORITY"; fi }                 # 20% LOW_PRIORITY
quick()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "QUICK"; fi }                        # 20% QUICK
limit()    { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `n10`"; fi }                  # 50% LIMIT 1-10
natural()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "NATURAL"; fi }                      # 20% NATURAL (for JOINs)
outer()    { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "OUTER"; fi }                        # 50% OUTER (for JOINs)
partition(){ if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "PARTITION p`n3`"; fi }              # 20% PARTITION p1-3
# ========================================= Single, fixed
alias2()   { echo "a`n2`"; }
alias3()   { echo "a`n3`"; }
asalias2() { echo "AS a`n2`"; }
asalias3() { echo "AS a`n3`"; }
# ========================================= Dual
onoff()    { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "ON"; else echo "OFF"; fi }          # 75% ON, 25% OFF
globses()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi }  # 50% GLOBAL, 50% SESSION
andor()    { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AND"; else echo "OR"; fi }          # 50% AND, 50% OR
leftright(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LEFT"; else echo "RIGHT"; fi }      # 50% LEFT, 50% RIGHT (for JOINs)
readwrite(){ if [ $[$RANDOM % 20 + 1] -le 1  ]; then echo "READ ONLY,"; else echo "READ WRITE,"; fi }  # 5% R/O, 95% R/W
# ========================================= Triple
emglobses(){ if [ $[$RANDOM % 20 + 1] -le 14 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi; fi }  # 35% GLOBAL, 35% SESSION, 30% EMPTY/NOTHING
emascdesc(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ASC"; else echo "DESC"; fi; fi }        # 25% ASC, 25% DESC, 50% EMPTY/NOTHING
bincharco(){ if [ $[$RANDOM % 30 + 1] -le 10 ]; then echo 'CHARACTER SET "Binary" COLLATE "Binary"'; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo 'CHARACTER SET "utf8" COLLATE "utf8_bin"'; else echo 'CHARACTER SET "latin1" COLLATE "latin1_bin"'; fi; fi }                                                                                                                      # 33% Binary/Binary, 33% utf8/utf8_bin, 33% latin1/latin1_bin
# ========================================= Quadruple
isolation(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ COMMITTED"; else echo "REPEATABLE READ"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ UNCOMMITTED"; else echo "SERIALIZABLE"; fi; fi; }                                                                               # 25% READ COMMITTED, 25% REPEATABLE READ, 25% READ UNCOMMITTED, 25% SERIALIZABLE
# ========================================= Quintuple
operator() { if [ $[$RANDOM % 20 + 1] -le 8 ]; then echo "="; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ">"; else echo ">="; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "<"; else echo "<="; fi; fi; fi; }                                                                        # 40% =, 15% >, 15% >=, 15% <, 15% <=
# ========================================= Subcalls
subwhere() { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "`andor` `whereal`"; fi }            # 20% sub-WHERE (additional and/or WHERE clause)
subordby() { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo ",c`n3` `emascdesc`"; fi }           # 20% sub-ORDER BY (additional ORDER BY column)
# ========================================= Complex
where()    { echo "`whereal`" | sed 's|a[0-9]\+\.||g'; }                                       # where():    e.g. WHERE    c1==c2    etc. (not suitable for multi-table WHERE's with similar column names)
wheretbl() { echo "`where`" | sed "s|\(c[0-9]\+\)|`table`.\1|g"; }                             # wheretbl(): e.g. WHERE t1.c1==t2.c2 etc. (may mismatch on table names if many or few tables are used)
whereal()  {                                                                                   # whereal():  e.g. WHERE a1.c1==a2.c2 etc. (requires table aliases to be in place)
  case $[$RANDOM % 4 + 1] in 
[1-2]) ;;  # 50% No WHERE clause
    3) echo "WHERE `alias3`.c`n3``operator``data` `subwhere`";;
    4) echo "WHERE `alias3`.c`n3``operator``alias3`.c`n3` `subwhere`";;
    *) echo "Assert: invalid random case selection in where() case"; exit 1;;
  esac
}
orderby()  { 
  case $[$RANDOM % 2 + 1] in 
    1) ;;  # 50% No ORDER BY clause
    2) echo "ORDER BY c`n3` `emascdesc` `subordby`";;
    *) echo "Assert: invalid random case selection in orderby() case"; exit 1;;
  esac
}
join()     { 
  case $[$RANDOM % 9 + 1] in 
    1) echo ",";;
    2) echo "JOIN";;
[3-6]) echo "`natural` `leftright` `outer` JOIN";;
    7) echo "INNER JOIN";;
    8) echo "CROSS JOIN";;
    9) echo "STRAIGHT_JOIN";;
    *) echo "Assert: invalid random case selection in orderby() case"; exit 1;;
  esac
}

if [ -r out.sql ]; then rm out.sql; fi
touch out.sql
if [ ! -r out.sql ]; then echo "Assert: out.sql not present after 'touch out.sql' command!"; exit 1; fi

for i in `eval echo {1..${queries}}`; do
  #FIXEDTABLE1=`table`  # A fixed table name: this can be used in queries where a unchanging table name is required to ensure the query works properly. For example, SELECT t1.c1 FROM t1;
  #FIXEDTABLE2=${FIXEDTABLE1}; while [ "${FIXEDTABLE1}" -eq "${FIXEDTABLE2}" ]; do FIXEDTABLE2=`table`; done  # A secondary fixed table, different from the first fixed table
  case $[$RANDOM % 20 + 1] in
    [1-4]) case $[$RANDOM % 3 + 1] in
        1) echo "CREATE `temp` TABLE `table` (c1 `pk`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`;" >> out.sql;;
        2) echo "CREATE `temp` TABLE `table` (c1 `ctype`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`;" >> out.sql;;
        3) C1TYPE=`ctype`
        if [ "`echo ${C1TYPE} | grep -o 'CHAR'`" == "CHAR" -o "`echo ${C1TYPE} | grep -o 'BLOB'`" == "BLOB" -o "`echo ${C1TYPE} | grep -o 'TEXT'`" == "TEXT" ]; then 
          echo "CREATE `temp` TABLE `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1(`n10`))) ENGINE=`engine`;" >> out.sql
        else
          echo "CREATE `temp` TABLE `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1)) ENGINE=`engine`;" >> out.sql
        fi;;
        *) echo "Assert: invalid random case selection in main create_table() case"; exit 1;;
      esac;;
    [5-6]) echo "DROP TABLE `table`;" >> out.sql;;
    [7-9]) echo "INSERT INTO `table` VALUES (`data`,`data`,`data`);" >> out.sql;;
    10) case $[$RANDOM % 3 + 1] in
        1) echo "SELECT c1 FROM `table`;" >> out.sql;;
        2) echo "SELECT c1,c2 FROM `table`;" >> out.sql;;
        3) echo "SELECT c1,c2 FROM `table` AS a1 `join` `table` AS a2 `whereal`;" >> out.sql;;
      esac;;
    11) case $[$RANDOM % 9 + 1] in
        1) echo "DELETE `lowprio` `quick` `ignore` FROM `table` `partition` `where` `orderby` `limit`;" >> out.sql;;
        2) echo "DELETE `lowprio` `quick` `ignore` `alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        3) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        4) echo "DELETE `lowprio` `quick` `ignore` `alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        5) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        6) echo "DELETE `lowprio` `quick` `ignore` `alias3`,`alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        7) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3`,`alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        8) echo "DELETE `alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
        9) echo "DELETE FROM `alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`;" >> out.sql;;
      esac;;
    12) echo "TRUNCATE `table`;" >> out.sql;;
    13) case $[$RANDOM % 2 + 1] in
        1) echo "UPDATE `table` SET c1=`data`;" >> out.sql;;
        2) echo "UPDATE `table` SET c1=`data` `where` `orderby` `limit`;" >> out.sql;;
        *) echo "Assert: invalid random case selection in UPDATE subcase"; exit 1;;
      esac;;
    1[4-6]) case $[$RANDOM % 7 + 1] in  # Generic statements
      [1-2]) echo "UNLOCK TABLES;" >> out.sql;;
      [3-4]) echo "SET AUTOCOMMIT=ON;"  >> out.sql;;
         5) echo "`flush`" | sed "s|DUMMY|`table`|;s|$|;|" >> out.sql;;
         6) echo "`trx`" | sed "s|DUMMY|`table`|;s|$|;|" >> out.sql;;
         7) echo "`reset`;" >> out.sql;;
         *) echo "Assert: invalid random case selection in generic statements subcase"; exit 1;;
      esac;;
    17) echo "SET `emglobses` TRANSACTION `readwrite` ISOLATION LEVEL `isolation`;" >> out.sql;;  # Isolation level | Excludes `COMMIT...RELEASE` SQL, as this drops CLI connection, though would be fine for pquery runs in principle
    1[8-9]) case $[$RANDOM % 7 + 1] in  # SET statements 
         # 1+2: Add or remove an SQL_MODE, with thanks http://johnemb.blogspot.com.au/2014/09/adding-or-removing-individual-sql-modes.html
         1) echo "SET @@`globses`.SQL_MODE=(SELECT CONCAT(@@SQL_MODE,',`sqlmode`'));" >> out.sql;;
         2) echo "SET @@`globses`.SQL_MODE=(SELECT REPLACE(@@SQL_MODE,',`sqlmode`',''));" >> out.sql;;
         3) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`setval`|;s|$|;|" >> out.sql;;  # The global/session vars also include sql_mode, which is like a 'reset' of sql_mode
         4) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`setval`|;s|$|;|" >> out.sql;;  # Note the servarS vs setvarG difference
         5) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`n100`|;s|$|;|" >> out.sql;;    # The global/session vars also include sql_mode, which is like a 'reset' of sql_mode
         6) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`n100`|;s|$|;|" >> out.sql;;    # Note the servarS vs setvarG difference
         7) echo "SET @@`globses`.OPTIMIZER_SWITCH=\"`optsw`=`onoff`\";" >> out.sql;;
         *) echo "Assert: invalid random case selection in generic statements subcase"; exit 1;;
      esac;;
    20) case $[$RANDOM % 9 + 1] in  # Alter
         1) echo "ALTER TABLE `table` ADD COLUMN c4 `ctype`;" >> out.sql;;
         2) echo "ALTER TABLE `table` DROP COLUMN c`n3`;" >> out.sql;;
         3) echo "ALTER TABLE `table` ENGINE=`engine`;" >> out.sql;;
         4) echo "ALTER TABLE `table` DROP PRIMARY KEY;" >> out.sql;;
         5) echo "ALTER TABLE `table` ADD INDEX (c`n3`);" >> out.sql;;
         6) echo "ALTER TABLE `table` ADD UNIQUE (c`n3`);" >> out.sql;;
         7) echo "ALTER TABLE `table` ADD INDEX (c`n3`), ADD UNIQUE (c`n3`);" >> out.sql;;
         8) C1TYPE=`ctype`
            if [ "$(echo "${C1TYPE}" | grep -oE "TEXT|CHAR|ENUM|SET")" != "" -a "$(echo "${C1TYPE}" | grep -oE "CHARACTER SET|COLLATE")" == "" ]; then  # First condition: field is text based, second condition: no charset/col present yet
              echo "ALTER TABLE `table` MODIFY c`n3` ${C1TYPE} `bincharco`;" >> out.sql
            else
              echo "ALTER TABLE `table` MODIFY c`n3` ${C1TYPE}" >> out.sql
            fi;;
         9) echo "ALTER TABLE `table` MODIFY c`n3` `ctype`;" >> out.sql;;
         *) echo "Assert: invalid random case selection in ALTER subcase"; exit 1;;
       esac;;
    21) case $[$RANDOM % 6 + 1] in  # Alter
         1) echo "SHOW TABLES;" >> out.sql;;
         2) echo "SHOW ENGINE `engine` STATUS;" >> out.sql;;
         3) echo "SHOW ENGINE `engine` MUTEX;" >> out.sql;;
         5) echo "SHOW ENGINES;" >> out.sql;;
         6) echo "SHOW WARNINGS;" >> out.sql;;
         *) echo "Assert: invalid random case selection in SHOW subcase"; exit 1;;
       esac;;
    22) case $[$RANDOM % 3 + 1] in  # Alter
         1) echo "SET GLOBAL innodb_monitor_enable='`inmetrics`';" >> out.sql;;
         2) echo "SET GLOBAL innodb_monitor_reset='`inmetrics`';" >> out.sql;;
         3) echo "SET GLOBAL innodb_monitor_disable='`inmetrics`';" >> out.sql;;
         *) echo "Assert: invalid random case selection in InnoDB metrics subcase"; exit 1;;
       esac;;
     *) echo "Assert: invalid random case selection in main case"; exit 1;;
  esac
done

sed -i "s|\t| |g;s|  \+| |g;s|[ ]*,|,|g" out.sql     # Replace tabs to spaces, replace double or more spaces with single space, remove spaces when in front of a comma

echo "Done! Generated ${queries} quality queries and saved the results in out.sql"
echo "Please note you may want to do:  \$ sed -i \"s|RocksDB|InnoDB|;s|TokuDB|InnoDB|\" out.sql  # depending on what distribution you are using. Or, edit engines.txt and run generator.sh again"
