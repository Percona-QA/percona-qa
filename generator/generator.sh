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
SUBWHEREACTIVE=0

# Check all needed data files are present
if [ ! -r tables.txt ]; then echo "Assert: tables.txt not found!"; exit 1; fi
if [ ! -r views.txt ]; then echo "Assert: views.txt not found!"; exit 1; fi
if [ ! -r pk.txt ]; then echo "Assert: pk.txt not found!"; exit 1; fi
if [ ! -r types.txt ]; then echo "Assert: types.txt not found!"; exit 1; fi
if [ ! -r data.txt ]; then echo "Assert: data.txt not found!"; exit 1; fi
if [ ! -r engines.txt ]; then echo "Assert: engines.txt not found!"; exit 1; fi
if [ ! -r a-z.txt ]; then echo "Assert: a-z.txt not found!"; exit 1; fi
if [ ! -r 0-9.txt ]; then echo "Assert: 0-9.txt not found!"; exit 1; fi
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
if [ ! -r event.txt ]; then echo "Assert: event.txt not found!"; exit 1; fi
if [ ! -r func.txt ]; then echo "Assert: func.txt not found!"; exit 1; fi
if [ ! -r proc.txt ]; then echo "Assert: proc.txt not found!"; exit 1; fi
if [ ! -r trigger.txt ]; then echo "Assert: trigger.txt not found!"; exit 1; fi
if [ ! -r users.txt ]; then echo "Assert: users.txt not found!"; exit 1; fi
if [ ! -r profiletypes.txt ]; then echo "Assert: profiletypes.txt not found!"; exit 1; fi
if [ ! -r interval.txt ]; then echo "Assert: interval.txt not found!"; exit 1; fi

# Read data files into arrays
mapfile -t tables    < tables.txt       ; TABLES=${#tables[*]}
mapfile -t views     < views.txt        ; VIEWS=${#views[*]}
mapfile -t pk        < pk.txt           ; PK=${#pk[*]}
mapfile -t types     < types.txt        ; TYPES=${#types[*]}
mapfile -t data      < data.txt         ; DATA=${#data[*]}
mapfile -t engines   < engines.txt      ; ENGINES=${#engines[*]}
mapfile -t az        < a-z.txt          ; AZ=${#az[*]}
mapfile -t n9        < 0-9.txt          ; N9=${#n9[*]}
mapfile -t n3        < 1-3.txt          ; N3=${#n3[*]}
mapfile -t n10       < 1-10.txt         ; N10=${#n10[*]}
mapfile -t n100      < 1-100.txt        ; N100=${#n100[*]}
mapfile -t n1000     < 1-1000.txt       ; N1000=${#n1000[*]}
mapfile -t trx       < trx.txt          ; TRX=${#trx[*]}
mapfile -t flush     < flush.txt        ; FLUSH=${#flush[*]}
mapfile -t lock      < lock.txt         ; LOCK=${#lock[*]}
mapfile -t reset     < reset.txt        ; RESET=${#reset[*]}
mapfile -t setvars   < session_$MYSQL_VERSION.txt; SETVARS=${#setvars[*]}
mapfile -t setvarg   < global_$MYSQL_VERSION.txt ; SETVARG=${#setvarg[*]}
mapfile -t setvals   < setvalues.txt    ; SETVALUES=${#setvals[*]}
mapfile -t sqlmode   < sqlmode.txt      ; SQLMODE=${#sqlmode[*]}
mapfile -t optsw     < optimizersw.txt  ; OPTSW=${#optsw[*]}
mapfile -t inmetrics < inmetrics.txt    ; INMETRICS=${#inmetrics[*]}
mapfile -t event     < event.txt        ; EVENT=${#event[*]}
mapfile -t func      < func.txt         ; FUNC=${#func[*]}
mapfile -t proc      < proc.txt         ; PROC=${#proc[*]}
mapfile -t trigger   < trigger.txt      ; TRIGGER=${#trigger[*]}
mapfile -t users     < users.txt        ; USERS=${#users[*]}
mapfile -t proftypes < profiletypes.txt ; PROFTYPES=${#proftypes[*]}
mapfile -t interval  < interval.txt     ; INTERVAL=${#interval[*]}

if [ ${TABLES} -lt 2 ]; then echo "Assert: number of table names is less then 2. A minimum of two tables is required for proper operation. Please ensure tables.txt has at least two table names"; exit 1; fi
   
# ========================================= From arrays
table()     { echo "${tables[$[$RANDOM % $TABLES]]}"; }
view()      { echo "${views[$[$RANDOM % $VIEWS]]}"; }
pk()        { echo "${pk[$[$RANDOM % $PK]]}"; }
ctype()     { echo "${types[$[$RANDOM % $TYPES]]}"; }
data()      { echo "${data[$[$RANDOM % $DATA]]}"; }
engine()    { echo "${engines[$[$RANDOM % $ENGINES]]}"; }
az()        { echo "${az[$[$RANDOM % $AZ]]}"; }
n9()        { echo "${n9[$[$RANDOM % $N9]]}"; }
n3()        { echo "${n3[$[$RANDOM % $N3]]}"; }
n10()       { echo "${n10[$[$RANDOM % $N10]]}"; }
n100()      { echo "${n100[$[$RANDOM % $N100]]}"; }
n1000()     { echo "${n1000[$[$RANDOM % $N1000]]}"; }
trx()       { echo "${trx[$[$RANDOM % $TRX]]}"; }
flush()     { echo "${flush[$[$RANDOM % $FLUSH]]}"; }
lock()      { echo "${lock[$[$RANDOM % $LOCK]]}"; }
reset()     { echo "${reset[$[$RANDOM % $RESET]]}"; }
setvars()   { echo "${setvars[$[$RANDOM % $SETVARS]]}"; }
setvarg()   { echo "${setvarg[$[$RANDOM % $SETVARG]]}"; }
setval()    { echo "${setvals[$[$RANDOM % $SETVALUES]]}"; }
sqlmode()   { echo "${sqlmode[$[$RANDOM % $SQLMODE]]}"; }
optsw()     { echo "${optsw[$[$RANDOM % $OPTSW]]}"; }
inmetrics() { echo "${inmetrics[$[$RANDOM % $INMETRICS]]}"; }
event()     { echo "${event[$[$RANDOM % $EVENT]]}"; }
func()      { echo "${func[$[$RANDOM % $FUNC]]}"; }
proc()      { echo "${proc[$[$RANDOM % $PROC]]}"; }
trigger()   { echo "${trigger[$[$RANDOM % $TRIGGER]]}"; }
user()      { echo "${users[$[$RANDOM % $USERS]]}"; }
proftype()  { echo "${proftypes[$[$RANDOM % $PROFTYPES]]}"; }
interval()  { echo "${interval[$[$RANDOM % $INTERVAL]]}"; }
# ========================================= Combinations
azn9()      { if [ $[$RANDOM % 36 + 1] -le 26 ]; then echo "`az`"; else echo "`n9`"; fi }       # 26 Letters, 10 digits, equal total division => 1 random character a-z or 0-9
# ========================================= Single, random
n2()        { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "1"; else echo "2"; fi }             # 50% 1, 50% 2
temp()      { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "TEMPORARY "; fi }                   # 20% TEMPORARY
ignore()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "IGNORE"; fi }                       # 20% IGNORE
lowprio()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "LOW_PRIORITY"; fi }                 # 20% LOW_PRIORITY
quick()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "QUICK"; fi }                        # 20% QUICK
limit()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `n9`"; fi }                   # 50% LIMIT 0-9
ofslimit()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `limoffset``n9`"; fi }        # 50% LIMIT 0-9, with potential offset
natural()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "NATURAL"; fi }                      # 20% NATURAL (for JOINs)
outer()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "OUTER"; fi }                        # 50% OUTER (for JOINs)
partition() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "PARTITION p`n3`"; fi }              # 20% PARTITION p1-3
full()      { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "FULL"; fi }                         # 20% FULL
not()       { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "NOT"; fi }                          # 25% NOT
fromdb()    { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "FROM test"; fi }                    # 10% FROM test
limoffset() { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "`n3`,"; fi }                        # 10% 0-3 offset (for LIMITs)
offset()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "OFFSET `n9`"; fi }                  # 20% OFFSET 0-9
forquery()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "FORQUERY `n9`"; fi }                # 20% QUERY 0-9
onephase()  { if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "ONE PHASE"; fi }                    # 15% ONE PHASE
convertxid(){ if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "CONVERT XID"; fi }                  # 15% CONVERT XID
ifnotexist(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IF NOT EXISTS"; fi }                # 50% IF NOT EXISTS
ifexist()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IF EXISTS"; fi }                    # 50% IF EXISTS
completion(){ if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "ON COMPLETION `not` PRESERVE"; fi } # 25% ON COMPLETION [NOT] PRESERVE
comment()   { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "COMMENT '$(echo '`data`' | sed "s|'||g")'"; fi }  # 25% COMMENT
intervalad(){ if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "+ INTERVAL `n9` `interval`"; fi }   # 20% + 0-9 INTERVAL
# ========================================= Single, fixed
alias2()    { echo "a`n2`"; }
alias3()    { echo "a`n3`"; }
asalias2()  { echo "AS a`n2`"; }
asalias3()  { echo "AS a`n3`"; }
# ========================================= Dual (or more via subcall)
onoff()     { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "ON"; else echo "OFF"; fi }          # 75% ON, 25% OFF
startsends(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "STARTS"; else echo "ENDS"; fi }     # 50% STARTS, 50% ENDS
globses()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi }  # 50% GLOBAL, 50% SESSION
andor()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AND"; else echo "OR"; fi }          # 50% AND, 50% OR
leftright() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LEFT"; else echo "RIGHT"; fi }      # 50% LEFT, 50% RIGHT (for JOINs)
readwrite() { if [ $[$RANDOM % 20 + 1] -le 1  ]; then echo "READ ONLY,"; else echo "READ WRITE,"; fi }  # 5% R/O, 95% R/W
startbegin(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "START"; else echo "BEGIN"; fi }     # 50% START, 50% BEGIN
xid()       { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "'xid1'"; else echo "'xid2'"; fi }   # 75% xid1, 25% xid2
disenable() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ENABLE"; else echo "DISABLE"; fi }  # 50% ENABLE, 50% DISABLE
sdisenable(){ if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "`disenable`"; else echo "DISABLE ON SLAVE"; fi }  # 40% ENABLE, 40% DISALBE, 20% DISABLE ON SLAVE
schedule()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AT `timestamp` `intervalad`"; else echo "EVERY `n9` `interval` `opstend`"; fi }  # 50% AT, 50% EVERY (for EVENTs)
# ========================================= Triple
definer()   { if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "DEFINER=`user`"; else echo "DEFINER=CURRENT_USER"; fi; fi }  # 15% DEFINER=random user, 15% DEFINER=CURRENT USER, 70% EMPTY/NOTHING
suspendfm() { if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "SUSPEND"; else echo "SUSPEND FOR MIGRATE"; fi; fi }  # 15% SUSPEND, 15% SUSPEND FOR MIGRATE, 70% EMPTY/NOTHING
joinresume(){ if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "JOIN"; else echo "RESUME"; fi; fi }     # 15% JOIN, 15% RESUME, 70% EMPTY/NOTHING
emglobses() { if [ $[$RANDOM % 20 + 1] -le 14 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi; fi }  # 35% GLOBAL, 35% SESSION, 30% EMPTY/NOTHING
emascdesc() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ASC"; else echo "DESC"; fi; fi }        # 25% ASC, 25% DESC, 50% EMPTY/NOTHING
bincharco() { if [ $[$RANDOM % 30 + 1] -le 10 ]; then echo 'CHARACTER SET "Binary" COLLATE "Binary"'; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo 'CHARACTER SET "utf8" COLLATE "utf8_bin"'; else echo 'CHARACTER SET "latin1" COLLATE "latin1_bin"'; fi; fi }                                                                                                                      # 33% Binary/Binary, 33% utf8/utf8_bin, 33% latin1/latin1_bin
# ========================================= Quadruple
like()      { if [ $[$RANDOM % 20 + 1] -le 8  ]; then if [ $[$RANDOM % 20 + 1] -le 5 ]; then echo "LIKE '`azn9`'"; else echo "LIKE '`azn9`%'"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIKE '%`azn9`'"; else echo "LIKE '%`azn9`%'"; fi; fi; }                                                                                 # 10% LIKE '<char>', 30% LIKE '<char>%', 30% LIKE '%<char>', 30% LIKE '%<char>%'
isolation() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ COMMITTED"; else echo "REPEATABLE READ"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ UNCOMMITTED"; else echo "SERIALIZABLE"; fi; fi; }                                                                               # 25% READ COMMITTED, 25% REPEATABLE READ, 25% READ UNCOMMITTED, 25% SERIALIZABLE
timestamp() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "CURRENT_TIMESTAMP"; else echo "CURRENT_TIMESTAMP()"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NOW()"; else echo "`data`"; fi; fi; }                                                                                         # 25% CURRENT_TIMESTAMP, 25% CURRENT_TIMESTAMP(), 25% NOW(), 25% random data
# ========================================= Quintuple
operator()  { if [ $[$RANDOM % 20 + 1] -le 8 ]; then echo "="; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ">"; else echo ">="; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "<"; else echo "<="; fi; fi; fi; }                                                                        # 40% =, 15% >, 15% >=, 15% <, 15% <=
# ========================================= Subcalls
subwhact()  { if [ ${SUBWHEREACTIVE} -eq 0 ]; then echo "WHERE "; fi }                                   # Only use 'WHERE' if this is not a sub-WHERE, i.e. a call from subwhere()
subwhere()  { SUBWHEREACTIVE=1; if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "`andor` `whereal`"; fi; }  # 20% sub-WHERE (additional and/or WHERE clause)
subordby()  { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo ",c`n3` `emascdesc`"; fi }                    # 20% sub-ORDER BY (additional ORDER BY column)
# ========================================= Special/Complex
opstend()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "`startsends` `timestamp` `intervalad`"; fi } # 20% optional START/STOP (for EVENTs)
where()     { echo "`whereal`" | sed 's|a[0-9]\+\.||g'; }                                       # where():    e.g. WHERE    c1==c2    etc. (not suitable for multi-table WHERE's with similar column names)
wheretbl()  { echo "`where`" | sed "s|\(c[0-9]\+\)|`table`.\1|g"; }                             # wheretbl(): e.g. WHERE t1.c1==t2.c2 etc. (may mismatch on table names if many or few tables are used)
whereal()   {                                                                                   # whereal():  e.g. WHERE a1.c1==a2.c2 etc. (requires table aliases to be in place)
  case $[$RANDOM % 4 + 1] in 
[1-2]) ;;  # 50% No WHERE clause
    3) echo "`subwhact``alias3`.c`n3``operator``data` `subwhere`";; # `subwhact`: sub-WHERE active or not, ref subwhact(). Ensures 'WHERE' is not repeated in sub-WHERE's (WHERE x=y AND a=b should not repeat WHERE for a=b)
    4) echo "`subwhact``alias3`.c`n3``operator``alias3`.c`n3` `subwhere`";;
    *) echo "Assert: invalid random case selection in where() case"; exit 1;;
  esac
  SUBWHEREACTIVE=0
}
orderby()   { 
  case $[$RANDOM % 2 + 1] in 
    1) ;;  # 50% No ORDER BY clause
    2) echo "ORDER BY c`n3` `emascdesc` `subordby`";;
    *) echo "Assert: invalid random case selection in orderby() case"; exit 1;;
  esac
}
join()      { 
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

query(){
  #FIXEDTABLE1=`table`  # A fixed table name: this can be used in queries where a unchanging table name is required to ensure the query works properly. For example, SELECT t1.c1 FROM t1;
  #FIXEDTABLE2=${FIXEDTABLE1}; while [ "${FIXEDTABLE1}" -eq "${FIXEDTABLE2}" ]; do FIXEDTABLE2=`table`; done  # A secondary fixed table, different from the first fixed table
  case $[$RANDOM % 23 + 1] in
    # Frequencies for CREATE, INSERT, and DROP statements are well tuned, please do not change the ranges: CREATE (1-3), INSERT (4-7), DROP (8)
    # Most other statements have been frequency tuned also, but not to the same depth. If you find bugs (for example too many errors because of frequency), please fix them
    [1-3]) case $[$RANDOM % 4 + 1] in  # CREATE (needs further work)
        1) echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 `pk`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`";;
        2) echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 `ctype`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`";;
        3) C1TYPE=`ctype`
           if [ "`echo ${C1TYPE} | grep -o 'CHAR'`" == "CHAR" -o "`echo ${C1TYPE} | grep -o 'BLOB'`" == "BLOB" -o "`echo ${C1TYPE} | grep -o 'TEXT'`" == "TEXT" ]; then 
             echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1(`n10`))) ENGINE=`engine`"
           else
             echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1)) ENGINE=`engine`"
           fi;;
        #func,proc,trigger
        4) echo "CREATE `definer` EVENT `ifnotexist` `event` ON SCHEDULE `schedule` `completion` `sdisenable` `comment` DO `query`";;


 
        *) echo "Assert: invalid random case selection in CREATE TABLE case"; exit 1;;

      esac;;
    [4-7]) case $[$RANDOM % 2 + 1] in  # Insert (needs further work to insert per-column etc.)
        1) echo "INSERT INTO `table` VALUES (`data`,`data`,`data`)";;
        2) echo "INSERT INTO `table` SELECT * FROM `table`";;
        *) echo "Assert: invalid random case selection in INSERT case"; exit 1;;
      esac;;
    8)  case $[$RANDOM % 8 + 1] in  # Drop
    [1-5]) echo "DROP TABLE `ifexist` `table`";;
    [6-8]) echo "DROP EVENT `ifexist` `event`";; 
        *) echo "Assert: invalid random case selection in DROP case"; exit 1;;
      esac;;
    9)  case $[$RANDOM % 13 + 1] in  # XA
    [1-8]) echo "XA COMMIT `xid` `onephase`";;
        9) echo "XA `startbegin` `xid` `joinresume`";;
       10) echo "XA END `xid` `suspendfm`";;
       11) echo "XA PREPARE `xid`";;
       12) echo "XA ROLLBACK `xid`";;
       13) echo "XA RECOVER `convertxid`";;
        *) echo "Assert: invalid random case selection in XA case"; exit 1;;
      esac;;
    10) case $[$RANDOM % 3 + 1] in  # Select (needs further work)
        1) echo "SELECT c1 FROM `table`";;
        2) echo "SELECT c1,c2 FROM `table`";;
        3) echo "SELECT c1,c2 FROM `table` AS a1 `join` `table` AS a2 `whereal`";;
        *) echo "Assert: invalid random case selection in SELECT case"; exit 1;;
      esac;;
    11) case $[$RANDOM % 9 + 1] in  # Delete (complete)
        1) echo "DELETE `lowprio` `quick` `ignore` FROM `table` `partition` `where` `orderby` `limit`";;
        2) echo "DELETE `lowprio` `quick` `ignore` `alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        3) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        4) echo "DELETE `lowprio` `quick` `ignore` `alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        5) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        6) echo "DELETE `lowprio` `quick` `ignore` `alias3`,`alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        7) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3`,`alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        8) echo "DELETE `alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        9) echo "DELETE FROM `alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `join` `table` AS a3 `whereal`";;
        *) echo "Assert: invalid random case selection in DELETE case"; exit 1;;
      esac;;
    12) echo "TRUNCATE `table`";;  # Truncate
    13) case $[$RANDOM % 2 + 1] in  # UPDATE (needs further work)
        1) echo "UPDATE `table` SET c1=`data`";;
        2) echo "UPDATE `table` SET c1=`data` `where` `orderby` `limit`";;
        *) echo "Assert: invalid random case selection in UPDATE case"; exit 1;;
      esac;;
    1[4-6]) case $[$RANDOM % 7 + 1] in  # Generic statements (needs further work)
      [1-2]) echo "UNLOCK TABLES";;
      [3-4]) echo "SET AUTOCOMMIT=ON";;
        5) echo "`flush`" | sed "s|DUMMY|`table`|;s|$|;|";;
        6) echo "`trx`" | sed "s|DUMMY|`table`|;s|$|;|";;
        7) echo "`reset`";;
        *) echo "Assert: invalid random case selection in generic statements case"; exit 1;;
      esac;;
    17) echo "SET `emglobses` TRANSACTION `readwrite` ISOLATION LEVEL `isolation`";;  # Isolation level | Excludes `COMMIT...RELEASE` SQL, as this drops CLI connection, though would be fine for pquery runs in principle
    1[8-9]) case $[$RANDOM % 35 + 1] in  # SET statements (complete)
        # 1+2: Add or remove an SQL_MODE, with thanks http://johnemb.blogspot.com.au/2014/09/adding-or-removing-individual-sql-modes.html
        [1-5]) echo "SET @@`globses`.SQL_MODE=(SELECT CONCAT(@@SQL_MODE,',`sqlmode`'))";;
        [6-9]) echo "SET @@`globses`.SQL_MODE=(SELECT REPLACE(@@SQL_MODE,',`sqlmode`',''))";;
       1[0-4]) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`setval`|;s|$|;|";;  # The global/session vars also include sql_mode, which is like a 'reset' of sql_mode
       1[5-9]) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`setval`|;s|$|;|";;  # Note the servarS vs setvarG difference
       2[0-4]) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`n100`|;s|$|;|";;    # The global/session vars also include sql_mode, which is like a 'reset' of sql_mode
       2[5-9]) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`n100`|;s|$|;|";;    # Note the servarS vs setvarG difference
       3[0-4]) echo "SET @@`globses`.OPTIMIZER_SWITCH=\"`optsw`=`onoff`\"";;
       35) case $[$RANDOM % 1 + 1] in  # A few selected, more commonly needed, SET statements
          1) echo "SET @@GLOBAL.server_id=`n9`";;  # To make replication related items work better, SET GLOBAL server_id=<nr>; is required
          *) echo "Assert: invalid random case selection in generic statements case (commonly needed statements section)"; exit 1;;
        esac;;
        *) echo "Assert: invalid random case selection in generic statements case"; exit 1;;
      esac;;
    20) case $[$RANDOM % 9 + 1] in  # Alter (needs few other additions like table types etc)
        1) echo "ALTER TABLE `table` ADD COLUMN c4 `ctype`";;
        2) echo "ALTER TABLE `table` DROP COLUMN c`n3`";;
        3) echo "ALTER TABLE `table` ENGINE=`engine`";;
        4) echo "ALTER TABLE `table` DROP PRIMARY KEY";;
        5) echo "ALTER TABLE `table` ADD INDEX (c`n3`)";;
        6) echo "ALTER TABLE `table` ADD UNIQUE (c`n3`)";;
        7) echo "ALTER TABLE `table` ADD INDEX (c`n3`), ADD UNIQUE (c`n3`)";;
        8) C1TYPE=`ctype`
           if [ "$(echo "${C1TYPE}" | grep -oE "TEXT|CHAR|ENUM|SET")" != "" -a "$(echo "${C1TYPE}" | grep -oE "CHARACTER SET|COLLATE")" == "" ]; then  # First condition: field is text based, second condition: no charset/col present yet
             echo "ALTER TABLE `table` MODIFY c`n3` ${C1TYPE} `bincharco`"
           else
             echo "ALTER TABLE `table` MODIFY c`n3` ${C1TYPE}"
           fi;;
        9) echo "ALTER TABLE `table` MODIFY c`n3` `ctype`";;
        *) echo "Assert: invalid random case selection in ALTER case"; exit 1;;
       esac;;
    21) case $[$RANDOM % 42 + 1] in  # SHOW (complete, though a WHERE clause is possible here in all statements where LIKE is possible, but this would be complex to code)
        1) echo "SHOW BINARY LOGS";;
        2) echo "SHOW MASTER LOGS";;
        #) echo "SHOW BINLOG EVENTS [IN 'log_name'] [FROM pos] `ofslimit`";;
        3) echo "SHOW CHARACTER SET `like`";;
        4) echo "SHOW COLLATION `like`";;
        5) echo "SHOW `full` COLUMNS FROM `table` `fromdb` `like`";;  # Second FROM (if activated) is a FROM <database> 
        6) echo "SHOW CREATE DATABASE test";;
        7) echo "SHOW CREATE EVENT `event`";;
        8) echo "SHOW CREATE FUNCTION `func`";;
        9) echo "SHOW CREATE PROCEDURE `proc`";;
       10) echo "SHOW CREATE TABLE `table`";;
       11) echo "SHOW CREATE TRIGGER `trigger`";;
       12) echo "SHOW CREATE VIEW `view`";;
       13) echo "SHOW DATABASES `like`";;
       14) echo "SHOW ENGINE `engine` STATUS";;
       15) echo "SHOW ENGINE `engine` MUTEX";;
       16) echo "SHOW ENGINES";;
       17) echo "SHOW STORAGE ENGINES";;
       18) echo "SHOW ERRORS `ofslimit`";;
       19) echo "SHOW EVENTS";;
       20) echo "SHOW FUNCTION CODE `func`";;
       21) echo "SHOW FUNCTION STATUS `like`";;
       22) echo "SHOW GRANTS FOR `user`";;
       23) echo "SHOW INDEX FROM `table` `fromdb`";;
       24) echo "SHOW MASTER STATUS";;
       25) echo "SHOW OPEN TABLES `fromdb` `like`";;
       26) echo "SHOW PLUGINS";;
       27) echo "SHOW PROCEDURE CODE `proc`";;
       28) echo "SHOW PROCEDURE STATUS `like`";;
       29) echo "SHOW PRIVILEGES";;
       30) echo "SHOW `full` PROCESSLIST";;
       31) echo "SHOW PROFILE `proftype` `forquery` `offset` `limit`";;  # `proftypes` could be expanded to have multiple/sub types
       32) echo "SHOW PROFILES";;
       ##) echo "SHOW RELAYLOG EVENTS [IN 'log_name'] [FROM pos] `ofslimit`";;
       33) echo "SHOW SLAVE HOSTS";;
       34) echo "SHOW SLAVE STATUS";;
       35) echo "SHOW SLAVE STATUS NONBLOCKING";;
       36) echo "SHOW `globses` STATUS `like`";;
       37) echo "SHOW TABLE STATUS `fromdb` `like`";;
       38) echo "SHOW TABLES";;
       39) echo "SHOW `full` TABLES `fromdb` `like`";;
       40) echo "SHOW TRIGGERS `fromdb` `like`";;
       41) echo "SHOW `globses` VARIABLES `like`";;
       42) echo "SHOW WARNINGS `ofslimit`";;
        *) echo "Assert: invalid random case selection in SHOW case"; exit 1;;
       esac;;
    22) case $[$RANDOM % 3 + 1] in  # InnoDB monitor (complete)
         1) echo "SET GLOBAL innodb_monitor_enable='`inmetrics`'";;
         2) echo "SET GLOBAL innodb_monitor_reset='`inmetrics`'";;
         3) echo "SET GLOBAL innodb_monitor_reset_all='`inmetrics`'";;
         4) echo "SET GLOBAL innodb_monitor_disable='`inmetrics`'";;
         *) echo "Assert: invalid random case selection in InnoDB metrics case"; exit 1;;
       esac;;
    23) echo "EXPLAIN `query`";;  # Explain (needs further work)
    #24) PURGE/FLUSH
    #25) RESET
    #26) TRX (start/stop//...)
    
     # TIP: when adding new options, make sure to update the original case/esac to reflect the new number of options (the number behind the '%' in the case statement at the top of the list)
     *) echo "Assert: invalid random case selection in main case"; exit 1;;
  esac
}

# Main code
if [ -r out.sql ]; then rm out.sql; fi
touch out.sql; if [ ! -r out.sql ]; then echo "Assert: out.sql not present after 'touch out.sql' command!"; exit 1; fi
for i in `eval echo {1..${queries}}`; do
  echo "`query`;" >> out.sql
done

sed -i "s|\t| |g;s|  \+| |g;s|[ ]*,|,|g;s| ;$|;|" out.sql     # Replace tabs to spaces, replace double or more spaces with single space, remove spaces when in front of a comma

echo "Done! Generated ${queries} quality queries and saved the results in out.sql"
echo "Please note you may want to do:  \$ sed -i \"s|RocksDB|InnoDB|;s|TokuDB|InnoDB|\" out.sql  # depending on what distribution you are using. Or, edit engines.txt and run generator.sh again"
