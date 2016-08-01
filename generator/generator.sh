#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# User Variables
MYSQL_VERSION="57"   # Valid options: 56, 57. Do not use dot (.)
SHEDULING_ENABLED=0  # On/Off (1/0). When using this, please note that testcases need to be reduced using PQUERY_MULTI=1 in reducer.sh (as they are effectively multi-threaded due to sheduler threads), and that issue reproducibility may be lower (sheduling may not match original OS slicing, other running queries etc.). Still, using PQUERY_MULTI=1 a good number of issues are likely (TBD) to be reproducibile and thus reducable given reducer.sh's random replay functionality.

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
if [ ! -r n1000-1000.txt ]; then echo "Assert: n1000-1000.txt not found!"; exit 1; fi
if [ ! -r flush.txt ]; then echo "Assert: flush.txt not found!"; exit 1; fi
if [ ! -r lock.txt ]; then echo "Assert: lock.txt not found!"; exit 1; fi
if [ ! -r reset.txt ]; then echo "Assert: reset.txt not found!"; exit 1; fi
if [ ! -r charsetcol_$MYSQL_VERSION.txt ]; then echo "Assert: charsetcol_$MYSQL_VERSION.txt not found! Please run getallsetoptions.sh after setting VERSION=$MYSQL_VERSION inside the same, and copy the resulting files here"; exit 1; fi
if [ ! -r session_$MYSQL_VERSION.txt ]; then echo "Assert: session_$MYSQL_VERSION.txt not found! Please run getallsetoptions.sh after setting VERSION=$MYSQL_VERSION inside the same, and copy the resulting files here"; exit 1; fi
if [ ! -r global_$MYSQL_VERSION.txt ]; then echo "Assert: global_$MYSQL_VERSION.txt not found! Please run getallsetoptions.sh after setting VERSION=$MYSQL_VERSION inside the same, and copy the resulting files here"; exit 1; fi
if [ ! -r pstables_$MYSQL_VERSION.txt ]; then echo "Assert: pstables_$MYSQL_VERSION.txt not found!"; exit 1; fi
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
if [ ! -r lctimenames.txt ]; then echo "Assert: lctimenames.txt not found!"; exit 1; fi
if [ ! -r character.txt ]; then echo "Assert: character.txt not found!"; exit 1; fi
if [ ! -r numsimple.txt ]; then echo "Assert: numsimple.txt not found!"; exit 1; fi
if [ ! -r numeric.txt ]; then echo "Assert: numeric.txt not found!"; exit 1; fi

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
mapfile -t nn1000    < n1000-1000.txt   ; NN1000=${#nn1000[*]}
mapfile -t flush     < flush.txt        ; FLUSH=${#flush[*]}
mapfile -t lock      < lock.txt         ; LOCK=${#lock[*]}
mapfile -t reset     < reset.txt        ; RESET=${#reset[*]}
mapfile -t charcol   < charsetcol_$MYSQL_VERSION.txt; CHARCOL=${#charcol[*]}
mapfile -t setvars   < session_$MYSQL_VERSION.txt; SETVARS=${#setvars[*]}  # S(ession)
mapfile -t setvarg   < global_$MYSQL_VERSION.txt ; SETVARG=${#setvarg[*]}  # G(lobal)
mapfile -t pstables  < pstables_$MYSQL_VERSION.txt; PSTABLES=${#pstables[*]}
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
mapfile -t lctimenms < lctimenames.txt  ; LCTIMENMS=${#lctimenms[*]}
mapfile -t character < character.txt    ; CHARACTER=${#character[*]}
mapfile -t numsimple < numsimple.txt    ; NUMSIMPLE=${#numsimple[*]}
mapfile -t numeric   < numeric.txt      ; NUMERIC=${#numeric[*]}

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
nn1000()    { echo "${nn1000[$[$RANDOM % $NN1000]]}"; }
flush()     { echo "${flush[$[$RANDOM % $FLUSH]]}"; }
lock()      { echo "${lock[$[$RANDOM % $LOCK]]}"; }
reset()     { echo "${reset[$[$RANDOM % $RESET]]}"; }
charcol()   { echo "${charcol[$[$RANDOM % $CHARCOL]]}"; }
setvars()   { echo "${setvars[$[$RANDOM % $SETVARS]]}"; }
setvarg()   { echo "${setvarg[$[$RANDOM % $SETVARG]]}"; }
pstable()   { echo "${pstables[$[$RANDOM % $PSTABLES]]}"; }
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
lctimename(){ echo "${lctimenms[$[$RANDOM % $LCTIMENMS]]}"; }
character() { echo "${character[$[$RANDOM % $CHARACTER]]}"; }
numsimple() { echo "${numsimple[$[$RANDOM % $NUMSIMPLE]]}"; }
numeric() { echo "${numericop[$[$RANDOM % $NUMERIC]]}"; }
# ========================================= Combinations
azn9()      { if [ $[$RANDOM % 36 + 1] -le 26 ]; then echo "`az`"; else echo "`n9`"; fi }       # 26 Letters, 10 digits, equal total division => 1 random character a-z or 0-9
# ========================================= Single, random
temp()      { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "TEMPORARY "; fi }                   # 20% TEMPORARY
ignore()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "IGNORE"; fi }                       # 20% IGNORE
lowprio()   { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "LOW_PRIORITY"; fi }                 # 25% LOW_PRIORITY
quick()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "QUICK"; fi }                        # 20% QUICK
limit()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `n9`"; fi }                   # 50% LIMIT 0-9
ofslimit()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `limoffset``n9`"; fi }        # 50% LIMIT 0-9, with potential offset
natural()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "NATURAL"; fi }                      # 20% NATURAL (for JOINs)
outer()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "OUTER"; fi }                        # 50% OUTER (for JOINs)
partition() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "PARTITION p`n3`"; fi }              # 20% PARTITION p1-3
full()      { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "FULL"; fi }                         # 20% FULL
not()       { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "NOT"; fi }                          # 25% NOT
no()        { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "NO"; fi }                           # 40% NO (for transactions)
fromdb()    { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "FROM test"; fi }                    # 10% FROM test
limoffset() { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "`n3`,"; fi }                        # 10% 0-3 offset (for LIMITs)
offset()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "OFFSET `n9`"; fi }                  # 20% OFFSET 0-9
forquery()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "FORQUERY `n9`"; fi }                # 20% QUERY 0-9
onephase()  { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "ONE PHASE"; fi }                    # 80% ONE PHASE (needs to be high ref http://dev.mysql.com/doc/refman/5.7/en/xa-states.html)
convertxid(){ if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "CONVERT XID"; fi }                  # 15% CONVERT XID
ifnotexist(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IF NOT EXISTS"; fi }                # 50% IF NOT EXISTS
ifexist()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IF EXISTS"; fi }                    # 50% IF EXISTS
completion(){ if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "ON COMPLETION `not` PRESERVE"; fi } # 25% ON COMPLETION [NOT] PRESERVE
comment()   { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "COMMENT '$(echo '`data`' | sed "s|'||g")'"; fi }  # 25% COMMENT
intervalad(){ if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "+ INTERVAL `n9` `interval`"; fi }   # 20% + 0-9 INTERVAL
work()      { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "WORK"; fi }                         # 25% WORK (for transactions and savepoints)
savepoint() { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "SAVEPOINT"; fi }                    # 25% SAVEPOINT (for savepoints)
chain()     { if [ $[$RANDOM % 20 + 1] -le 7  ]; then echo "AND `no` CHAIN"; fi }               # 35% AND [NO] CHAIN (for transactions)
release()   { if [ $[$RANDOM % 20 + 1] -le 7  ]; then echo "NO RELEASE"; fi }                   # 35% NO RELEASE (for transactions). Plain 'RELEASE' is not possible, as this drops client connection
nowbinlog() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NO_WRITE_TO_BINLOG"; fi }           # 50% NO_WRITE_TO_BINLOG
localonly() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LOCAL"; fi }                        # 50% LOCAL (note 'local' is system keyword, hence 'localonly')
quick()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "QUICK"; fi }                        # 20% QUICK
extended()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "EXTENDED"; fi }                     # 20% EXTENDED
usefrm()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "USE_FRM"; fi }                      # 20% USE_FRM
# ========================================= Single, fixed
alias2()    { echo "a`n2`"; }
alias3()    { echo "a`n3`"; }
asalias2()  { echo "AS a`n2`"; }
asalias3()  { echo "AS a`n3`"; }
numericop() { echo "`numeric`" | sed "s|DUMMY|`danrorfull`|;s|DUMMY2|`danrorfull`|;s|DUMMY3|`danrorfull`|"; }                                # NUMERIC FUNCTION with data (includes numbers) or -1000 to 1000 as options, for example ABS(nr)
# ========================================= Dual
n2()        { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "1"; else echo "2"; fi }                                                          # 50% 1, 50% 2
onoff()     { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "ON"; else echo "OFF"; fi }                                                       # 75% ON, 25% OFF
onoff01()   { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "1"; else echo "0"; fi }                                                          # 75% 1 (on), 25% 0 (off)
allor1()    { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "*"; else echo "1"; fi }                                                          # 80% *, 20% 1
startsends(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "STARTS"; else echo "ENDS"; fi }                                                  # 50% STARTS, 50% ENDS
globses()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi }                                               # 50% GLOBAL, 50% SESSION
andor()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AND"; else echo "OR"; fi }                                                       # 50% AND, 50% OR
leftright() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LEFT"; else echo "RIGHT"; fi }                                                   # 50% LEFT, 50% RIGHT (for JOINs)
readwrite() { if [ $[$RANDOM % 20 + 1] -le 1  ]; then echo "READ ONLY,"; else echo "READ WRITE,"; fi }                                       # 5% R/O, 95% R/W
xid()       { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "'xid1'"; else echo "'xid2'"; fi }                                                # 75% xid1, 25% xid2
disenable() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ENABLE"; else echo "DISABLE"; fi }                                               # 50% ENABLE, 50% DISABLE
sdisenable(){ if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "`disenable`"; else echo "DISABLE ON SLAVE"; fi }                                 # 40% ENABLE, 40% DISALBE, 20% DISABLE ON SLAVE
schedule()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AT `timestamp` `intervalad`"; else echo "EVERY `n9` `interval` `opstend`"; fi }  # 50% AT, 50% EVERY (for EVENTs)
readwrite() { if [ $[$RANDOM % 30 + 1] -le 10 ]; then echo 'READ'; else echo 'WRITE'; fi }                                                   # 50% READ, 50% WRITE (for transactions)
binmaster() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "BINARY"; else echo "MASTER"; fi }                                                # 50% BINARY, 50% MASTER
nowblocal() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NO_WRITE_TO_BINLOG"; else echo "LOCAL"; fi }                                     # 50% NO_WRITE_TO_BINLOG, 50% LOCAL
locktype()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ `localonly`"; else echo "`lowprio` WRITE"; fi }                             # 50% READ [LOCAL], 50% [LOW_PRIORITY] WRITE
charactert(){ if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "`character` `charactert`"; else echo "`character`"; fi }                         # 40% NESTED CHARACTERISTIC, 60% SINGLE (OR FINAL) CHARACTERISTIC (increasing final possibility)
danrorfull(){ if [ $[$RANDOM % 20 + 1] -le 12 ]; then echo "`dataornum`"; else echo "`fullnrfunc`"; fi }                                     # 60% data (includes numbers) or -1000 to 1000, 40% full numeric function 
numericadd(){ if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "`nusimple` `eitherornn` `numericadd`"; else echo "`nusimple` `eitherornn`" ; fi }  # 40% NESTED +/-/etc. NR FUNCTION() OR SIMPLE, 60% SINGLE (OR FINAL) +/-/etc. as above
dataornum() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "`data`"; else echo "`nn1000`"; fi }                                              # 20% data (includes numbers), 80% -1000 to 1000
eitherornn(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`dataornum`"; else echo "`numericop`"; fi }                                      # 50% data/number (ref above), 50% NUMERIC FUNCTION() like ABS(nr) etc.
fullnrfunc(){ if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`eitherornn` `nusimple` `eitherornn`"; else echo "`eitherornn` `nusimple` `eitherornn` `numericadd`"; fi }  # 50% full numeric function, 50% idem with nesting
# ========================================= Triple
ac()        { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "a"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "b"; else echo "c"; fi; fi }  # 40% a, 30% b, 30% c
trxopt()    { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`readwrite`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "WITH CONSISTENT SNAPSHOT `readwrite`"; else echo "WITH CONSISTENT SNAPSHOT"; fi; fi }  # 50% R/W or R/O, 25% WITH C/S, 25% C/S + R/W or R/O
definer()   { if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "DEFINER=`user`"; else echo "DEFINER=CURRENT_USER"; fi; fi }  # 15% DEFINER=random user, 15% DEFINER=CURRENT USER, 70% EMPTY/NOTHING
suspendfm() { if [ $[$RANDOM % 20 + 1] -le 2  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "SUSPEND"; else echo "SUSPEND FOR MIGRATE"; fi; fi }  # 5% SUSPEND, 5% SUSPEND FOR MIGRATE, 90% EMPTY/NOTHING (needs to be low, ref url above)
joinresume(){ if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "JOIN"; else echo "RESUME"; fi; fi }      # 15% JOIN, 15% RESUME, 70% EMPTY/NOTHING
emglobses() { if [ $[$RANDOM % 20 + 1] -le 14 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi; fi }   # 35% GLOBAL, 35% SESSION, 30% EMPTY/NOTHING
emascdesc() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ASC"; else echo "DESC"; fi; fi }         # 25% ASC, 25% DESC, 50% EMPTY/NOTHING
bincharco() { if [ $[$RANDOM % 30 + 1] -le 10 ]; then echo 'CHARACTER SET "Binary" COLLATE "Binary"'; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo 'CHARACTER SET "utf8" COLLATE "utf8_bin"'; else echo 'CHARACTER SET "latin1" COLLATE "latin1_bin"'; fi; fi }                                                                                                                       # 33% Binary/Binary, 33% utf8/utf8_bin, 33% latin1/latin1_bin
inout()     { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "INOUT"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IN"; else echo "OUT"; fi; fi }  # 40% INOUT, 30% IN, 30% OUT
# ========================================= Quadruple
like()      { if [ $[$RANDOM % 20 + 1] -le 8  ]; then if [ $[$RANDOM % 20 + 1] -le 5 ]; then echo "LIKE '`azn9`'"; else echo "LIKE '`azn9`%'"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIKE '%`azn9`'"; else echo "LIKE '%`azn9`%'"; fi; fi; }                                                                                 # 10% LIKE '<char>', 30% LIKE '<char>%', 30% LIKE '%<char>', 30% LIKE '%<char>%'
isolation() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ COMMITTED"; else echo "REPEATABLE READ"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ UNCOMMITTED"; else echo "SERIALIZABLE"; fi; fi; }                                                                               # 25% READ COMMITTED, 25% REPEATABLE READ, 25% READ UNCOMMITTED, 25% SERIALIZABLE
timestamp() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "CURRENT_TIMESTAMP"; else echo "CURRENT_TIMESTAMP()"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NOW()"; else echo "`data`"; fi; fi; }                                                                                         # 25% CURRENT_TIMESTAMP, 25% CURRENT_TIMESTAMP(), 25% NOW(), 25% random data
# ========================================= Quintuple
operator()  { if [ $[$RANDOM % 20 + 1] -le 8 ]; then echo "="; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ">"; else echo ">="; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "<"; else echo "<="; fi; fi; fi; }                                                                        # 40% =, 15% >, 15% >=, 15% <, 15% <=
pstimer()   { if [ $[$RANDOM % 20 + 1] -le 4 ]; then echo "idle"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "wait"; else echo "stage"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "statement"; else echo "transaction"; fi; fi; fi; }                                              # 20% idle, 20% wait, 20% stage, 20% statement, 20% transaction
pstimernm() { if [ $[$RANDOM % 20 + 1] -le 4 ]; then echo "CYCLE"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NANOSECOND"; else echo "MICROSECOND"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "MILLISECOND"; else echo "TICK"; fi; fi; fi; }                                      # 20% CYCLE, 20% NANOSECOND, 20% MICROSECOND, 20% MILLISECOND, 20% TICK
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
    *) echo "Assert: invalid random case selection in where() case";;
  esac
  SUBWHEREACTIVE=0
}
orderby()   { 
  case $[$RANDOM % 2 + 1] in 
    1) ;;  # 50% No ORDER BY clause
    2) echo "ORDER BY c`n3` `emascdesc` `subordby`";;
    *) echo "Assert: invalid random case selection in orderby() case";;
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
    *) echo "Assert: invalid random case selection in orderby() case";;
  esac
}

query(){
  #FIXEDTABLE1=`table`  # A fixed table name: this can be used in queries where a unchanging table name is required to ensure the query works properly. For example, SELECT t1.c1 FROM t1;
  #FIXEDTABLE2=${FIXEDTABLE1}; while [ "${FIXEDTABLE1}" -eq "${FIXEDTABLE2}" ]; do FIXEDTABLE2=`table`; done  # A secondary fixed table, different from the first fixed table
  case $[$RANDOM % 39 + 1] in
    # Frequencies for CREATE (1-3), INSERT (4-7), and DROP (8) statements are well tuned, please do not change these case ranges
    # Most other statements have been frequency tuned also, but not to the same depth. If you find bugs (for example too many errors because of frequency), please fix them
    [1-3]) case $[$RANDOM % 6 + 1] in  # CREATE (needs further work)
        1) echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 `pk`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`";;
        2) echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 `ctype`,c2 `ctype`,c3 `ctype`) ENGINE=`engine`";;
        3) C1TYPE=`ctype`
           if [ "`echo ${C1TYPE} | grep -o 'CHAR'`" == "CHAR" -o "`echo ${C1TYPE} | grep -o 'BLOB'`" == "BLOB" -o "`echo ${C1TYPE} | grep -o 'TEXT'`" == "TEXT" ]; then 
             echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1(`n10`))) ENGINE=`engine`"
           else
             echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1)) ENGINE=`engine`"
           fi;;
        4) if [ $SHEDULING_ENABLED -eq 1 ]; then  # Events (complete)
             echo "CREATE `definer` EVENT `ifnotexist` `event` ON SCHEDULE `schedule` `completion` `sdisenable` `comment` DO `query`"
           else
             echo "`query`"
           fi;;
        5) case $[$RANDOM % 19 + 1] in  # Stored Functions (nearing completion, but some different functions can be added)
         [1-9]) echo "CREATE `definer` FUNCTION `func` (i1 `ctype`) RETURNS `ctype` `charactert` RETURN CONCAT('function output:',i1)";;
        1[0-8]) echo "CREATE `definer` FUNCTION `func` (i1 `ctype`,i2 `ctype`) RETURNS `ctype` `charactert` RETURN CONCAT('function output:',i1)";;
            19) echo "CREATE `definer` FUNCTION `func` (i1 `ctype`) RETURNS `ctype` `charactert` RETURN `query`";;  # Will highly likely fail, but good to test (e.g. 'FLUSH is not allowed in stored function or trigger' etc.)
             *) echo "Assert: invalid random case selection in functions case";;
           esac;;
        6) case $[$RANDOM % 2 + 1] in  # Stored Procedures
             1) echo "CREATE `definer` PROCEDURE `proc` (`inout` i1 `ctype`) `charactert` `query`";;
             2) echo "CREATE `definer` PROCEDURE `proc` (`inout` i1 `ctype`, `inout` i2 `ctype`) `charactert` `query`";;
             *) echo "Assert: invalid random case selection in procedures case";;
           esac;;
        7) 


      
        #todo: trigger,views
 
        *) echo "Assert: invalid random case selection in CREATE case";;
      esac;;
    [4-7]) case $[$RANDOM % 2 + 1] in  # Insert (needs further work to insert per-column etc.)
        1) echo "INSERT INTO `table` VALUES (`data`,`data`,`data`)";;
        2) echo "INSERT INTO `table` SELECT * FROM `table`";;
        *) echo "Assert: invalid random case selection in INSERT case";;
      esac;;
    8)  case $[$RANDOM % 11 + 1] in  # Drop
    [1-5]) echo "DROP TABLE `ifexist` `table`";;
    [6-7]) if [ $SHEDULING_ENABLED -eq 1 ]; then
             echo "DROP EVENT `ifexist` `event`"
           else
             echo "`query`"
           fi;; 
    [8-9]) echo "DROP FUNCTION `ifexist` `func`";;
   1[0-1]) echo "DROP PROCEDURE `ifexist` `proc`";;
        *) echo "Assert: invalid random case selection in DROP case";;
      esac;;
    9) case $[$RANDOM % 2 + 1] in  # Load data infile/select into outfile (needs further work)
        1) echo "LOAD DATA INFILE 'out`n9`' INTO TABLE `table`";;
        2) echo "SELECT * FROM `table` INTO OUTFILE 'out`n9`'";;
        *) echo "Assert: invalid random case selection in load data infile/select into outfile case";;
      esac;;
    10) case $[$RANDOM % 3 + 1] in  # Select (needs further work)
        1) echo "SELECT c1 FROM `table`";;
        2) echo "SELECT c1,c2 FROM `table`";;
        3) echo "SELECT c1,c2 FROM `table` AS a1 `join` `table` AS a2 `whereal`";;
        *) echo "Assert: invalid random case selection in SELECT case";;
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
        *) echo "Assert: invalid random case selection in DELETE case";;
      esac;;
    12) echo "TRUNCATE `table`";;  # Truncate
    13) case $[$RANDOM % 2 + 1] in  # UPDATE (needs further work)
        1) echo "UPDATE `table` SET c1=`data`";;
        2) echo "UPDATE `table` SET c1=`data` `where` `orderby` `limit`";;
        *) echo "Assert: invalid random case selection in UPDATE case";;
      esac;;
    1[4-6]) case $[$RANDOM % 7 + 1] in  # Generic statements (needs further work except flush and reset)
      [1-2]) echo "UNLOCK TABLES";;
      [3-4]) echo "SET AUTOCOMMIT=ON";;
        5) echo "FLUSH `nowbinlog` `localonly` `flush`" | sed "s|DUMMY|`table`|";;
        6) echo "`reset`";;
        7) echo "PURGE `binmaster` LOGS";; # Add TO and BEFORE clauses (need a datetime generator)
        *) echo "Assert: invalid random case selection in generic statements case";;
      esac;;
    17) echo "SET `emglobses` TRANSACTION `readwrite` ISOLATION LEVEL `isolation`";;  # Isolation level | Excludes `COMMIT...RELEASE` SQL, as this drops client connection
    1[8-9]) case $[$RANDOM % 37 + 1] in  # SET statements (complete)
        # 1+2: Add or remove an SQL_MODE, with thanks http://johnemb.blogspot.com.au/2014/09/adding-or-removing-individual-sql-modes.html
        [1-5]) echo "SET @@`globses`.SQL_MODE=(SELECT CONCAT(@@SQL_MODE,',`sqlmode`'))";;
        [6-9]) echo "SET @@`globses`.SQL_MODE=(SELECT REPLACE(@@SQL_MODE,',`sqlmode`',''))";;
       1[0-4]) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`setval`|";;  # The global/session vars also include sql_mode, which is like a 'reset' of sql_mode
       1[5-9]) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`setval`|";;  # Note the servarS vs setvarG difference
       2[0-4]) echo "SET @@SESSION.`setvars`" | sed "s|DUMMY|`n100`|";;    # The global/session vars also include sql_mode, which is like a 'reset' of sql_mode
       2[5-9]) echo "SET @@GLOBAL.`setvarg`"  | sed "s|DUMMY|`n100`|";;    # Note the servarS vs setvarG difference
       3[0-4]) echo "SET @@`globses`.OPTIMIZER_SWITCH=\"`optsw`=`onoff`\"";;
       35) case $[$RANDOM % 1 + 1] in  # Charset/collation related SET statements 
             1) echo "SET @@`globses`.`charcol`";;  # Charset/collation changes (all SET parameters are indentical for global and session atm)
             2) echo "SET @@`globses`.lc_time_names=`lctimename`";;  # http://dev.mysql.com/doc/refman/5.7/en/locale-support.html
             *) echo "Assert: invalid random case selection in generic statements case (charset/collation section)";;
           esac;;
       3[6-7]) case $[$RANDOM % 5 + 1] in  # A few selected (more commonly needed, except the first) SET statements that get a higher frequency then the ones above
             1) echo "SET @@GLOBAL.default_storage_engine=`engine`";;
             2) echo "SET @@GLOBAL.server_id=`n9`";;  # To make replication related items work better, SET GLOBAL server_id=<nr>; is required
             3) echo "SET @@`globses`.tx_read_only=0";;  # Ensure tx_read_only regularly set back to off
             4) echo "SET @@GLOBAL.read_only=0";;        # Idem, for read_only
             5) echo "SET @@GLOBAL.super_read_only=0";;  # Idem, for super_read_only
             *) echo "Assert: invalid random case selection in generic statements case (commonly needed statements section)";;
           esac;;
        *) echo "Assert: invalid random case selection in generic statements case";;
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
        *) echo "Assert: invalid random case selection in ALTER case";;
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
        *) echo "Assert: invalid random case selection in SHOW case";;
       esac;;
    22) case $[$RANDOM % 4 + 1] in  # InnoDB monitor (complete)
        1) echo "SET GLOBAL innodb_monitor_enable='`inmetrics`'";;
        2) echo "SET GLOBAL innodb_monitor_reset='`inmetrics`'";;
        3) echo "SET GLOBAL innodb_monitor_reset_all='`inmetrics`'";;
        4) echo "SET GLOBAL innodb_monitor_disable='`inmetrics`'";;
        *) echo "Assert: invalid random case selection in InnoDB metrics case";;
      esac;;
    23) case $[$RANDOM % 7 + 1] in  # Nested `query` calls: items 1 and 2 need further work to not select all types of queries (needs sub-functions, for example select(){}
        1) echo "EXPLAIN `query`";;                # Explain (needs further work: as above + more explain clauses)
        2) echo "SELECT `allor1` FROM (`query`) AS a1";;  # Subquery (needs further work: as above + more subquery structures)
    [3-7]) case $[$RANDOM % 8 + 1] in  # Prepared statements (needs further work)
       [1-3]) echo "SET @cmd:='`query`'";;
       [4-5]) echo "PREPARE stmt FROM @cmd";;
       [6-7]) echo "EXECUTE stmt";;
           8) echo "DEALLOCATE PREPARE stmt";;
           *) echo "Assert: invalid random case selection in prepared statements case";;
          esac;;
        *) echo "Assert: invalid random case selection in nested query calls case";;
      esac;;
2[4-8]) case $[$RANDOM % 24 + 1] in  # XA (complete)
        # Frequencies for XA: COMMIT (1-9), START/BEGIN (10), END (11-17), PREPARE (19), RECOVER (20), and ROLLBACK (21-24) statements are well tuned, please do not change these case ranges
    [1-9]) echo "XA COMMIT `xid` `onephase`";;
       10) case $[$RANDOM % 2 + 1] in
           1) echo "XA START `xid`";;
           2) echo "XA BEGIN `xid` `joinresume`";;
         esac;;
   1[1-8]) echo "XA END `xid` `suspendfm`";;
       19) echo "XA PREPARE `xid`";;
       20) echo "XA RECOVER `convertxid`";;
   2[1-4]) echo "XA ROLLBACK `xid`";;
        *) echo "Assert: invalid random case selection in XA case";;
      esac;;
    29) case $[$RANDOM % 5 + 1] in  # Repair/optimize/analyze/rename/truncate table (complete)
        1) echo "REPAIR `nowblocal` TABLE `table` `quick` `extended` `usefrm`";;
        2) echo "OPTIMIZE `nowblocal` TABLE `table`";;
        3) echo "ANALYZE `nowblocal` TABLE `table`";;
        4) case $[$RANDOM % 3 + 1] in
           1) echo "RENAME TABLE `table` TO `table`";;
           2) echo "RENAME TABLE `table` TO `table`,`table` TO `table`";;
           3) echo "RENAME TABLE `table` TO `table`,`table` TO `table`,`table` TO `table`";;
           *) echo "Assert: invalid random case selection in rename table case";;
           esac;;
        5) echo "TRUNCATE TABLE `table`";;
        *) echo "Assert: invalid random case selection in repair/optimize/analyze/rename/truncate table case";;
      esac;;
3[0-1]) case $[$RANDOM % 7 + 1] in  # Transactions (complete, except review/add in different section?; http://dev.mysql.com/doc/refman/5.7/en/begin-end.html) 
        1) echo "START TRANSACTION `trxopt`";;
        2) echo "BEGIN `work`";;
    [3-4]) echo "COMMIT `work` `chain` `release`";;
    [5-6]) echo "ROLLBACK `work` `chain` `release`";;
        7) echo "SET autocommit=`onoff01`";;
        *) echo "Assert: invalid random case selection in transactions case";;
      esac;;
    32) case $[$RANDOM % 2 + 1] in  # Lock tables (complete)
        1) echo "LOCK TABLES `table` `asalias3` `locktype`";;
        2) echo "UNLOCK TABLES";; 
        *) echo "Assert: invalid random case selection in lock case";;
      esac;;
    33) case $[$RANDOM % 3 + 1] in  # Savepoints (complete)
        1) echo "SAVEPOINT sp`n2`";;
        2) echo "ROLLBACK `work` TO `savepoint` sp`n2`";;
        3) echo "RELEASE SAVEPOINT sp`n2`";;
        *) echo "Assert: invalid random case selection in savepoint case";;
      esac;;
3[4-5]) case $[$RANDOM % 13 + 1] in  # P_S (in progress) | To check: TRUNCATE of tables does not seem to work: bug? https://dev.mysql.com/doc/refman/5.7/en/setup-timers-table.html
    [1-2]) case $[$RANDOM % 5 + 1] in  # Enabling and truncating
          1) echo "UPDATE performance_schema.setup_instruments SET ENABLED = 'YES', TIMED = 'YES'";;
          2) echo "UPDATE performance_schema.setup_consumers SET ENABLED = 'YES'";;
          3) echo "UPDATE performance_schema.setup_objects SET ENABLED = 'YES', TIMED = 'YES'";;
          4) echo "UPDATE performance_schema.setup_timers SET TIMER_NAME='`pstimernm`' WHERE NAME='`pstimer`'";;
          5) PSTBL=`pstable`; if ! [[ "${PSTBL}" == *"setup"* ]]; then echo "TRUNCATE TABLE performance_schema.${PSTBL}"; else echo "`query`"; fi;;
          *) echo "Assert: invalid random case selection in P_S enabling subcase";;
          esac;;
    [3-9]) echo "SELECT * FROM performance_schema.`pstable`";;
   1[0-3]) case $[$RANDOM % 10 + 1] in  # Special setup for stress testing PXC 5.7, remove later
          1) echo "UPDATE performance_schema.setup_instruments SET ENABLED = 'YES', TIMED = 'YES' WHERE NAME LIKE '%wsrep%'";;
          2) echo "UPDATE performance_schema.setup_instruments SET ENABLED = 'YES', TIMED = 'YES' WHERE NAME LIKE '%galera%'";;
          3) echo "SELECT EVENT_ID, EVENT_NAME, TIMER_WAIT FROM performance_schema.events_waits_history WHERE EVENT_NAME LIKE '%galera%'";;
          4) echo "SELECT EVENT_ID, EVENT_NAME, TIMER_WAIT FROM performance_schema.events_waits_history WHERE EVENT_NAME LIKE '%wsrep%'";;
          5) echo "SELECT EVENT_NAME, COUNT_STAR FROM performance_schema.events_waits_summary_global_by_event_name WHERE EVENT_NAME LIKE '%wsrep%'";;
          6) echo "SELECT EVENT_NAME, COUNT_STAR FROM performance_schema.events_waits_summary_global_by_event_name WHERE EVENT_NAME LIKE '%galera%'";;
          7) echo "SELECT * FROM performance_schema.file_instances WHERE FILE_NAME LIKE '%galera%'";;
          8) echo "SELECT * FROM performance_schema.events_stages_history WHERE EVENT_NAME LIKE '%wsrep%'";;
          9) echo "SELECT EVENT_ID, EVENT_NAME, TIMER_WAIT FROM performance_schema.events_waits_history WHERE EVENT_NAME LIKE '%galera%'";;
         10) echo "SELECT EVENT_ID, EVENT_NAME, TIMER_WAIT FROM performance_schema.events_waits_history WHERE EVENT_NAME LIKE '%wsrep%'";;
          *) echo "Assert: invalid random case selection in P_S PXC specific subcase";;
          esac;;
        *) echo "Assert: invalid random case selection in P_S subcase";;
      esac;;
3[6-7]) case $[$RANDOM % 4 + 1] in  # Calling/setup of functions, procedures (complete)
          1) echo "SET @`ac`=`data`";;
          2) echo "CALL `proc`(@`ac`)";;
          3) echo "SELECT @`ac`";;
          4) echo "SELECT `func`(`data`)";;
          *) echo "Assert: invalid random case selection in func,proc call subcase";;
        esac;;
3[8-9]) case $[$RANDOM % 4 + 1] in  # Numeric functions
         1) echo "`fullnrfunc`";;
         2) echo "(`fullnrfunc`) `nusimple` (`fullnrfunc`)";;
         3) echo "(`fullnrfunc`) `nusimple` (`fullnrfunc`) `nusimple` (`fullnrfunc`)";;
         4) echo "(`fullnrfunc`) `nusimple` (`fullnrfunc`) `nusimple` (`fullnrfunc`) `nusimple` (`fullnrfunc`)";;
         *) echo "Assert: invalid random case selection in func,proc call subcase";;
       esac;;
       
   

# http://dev.mysql.com/doc/refman/5.7/en/get-diagnostics.html
# http://dev.mysql.com/doc/refman/5.7/en/signal.html

 
    
     # TIP: when adding new options, make sure to update the original case/esac to reflect the new number of options (the number behind the '%' in the case statement at the top of the list matches the number of available 'nr)' options)
     *) echo "Assert: invalid random case selection in main case";;
  esac
}

# Main code
if [ -r out.sql ]; then rm out.sql; fi
touch out.sql; if [ ! -r out.sql ]; then echo "Assert: out.sql not present after 'touch out.sql' command!"; exit 1; fi
for i in `eval echo {1..${queries}}`; do
  echo "`query`;" >> out.sql
done
if grep -qi "Assert" out.sql; then
  echo "Errors found, please fix generator.sh code:"
  grep "Assert" out.sql | sort -u | sed 's|[ ]*;$||'
  rm out.sql 2>/dev/null
else
  sed -i "s|\t| |g;s|  \+| |g;s|[ ]*,|,|g;s|[ ]*;$|;|" out.sql  # Replace tabs to spaces, replace double or more spaces with single space, remove spaces when in front of a comma
  echo "Done! Generated ${queries} quality queries and saved the results in out.sql"
  echo "Please note you may want to do:  \$ sed -i \"s|RocksDB|InnoDB|;s|TokuDB|InnoDB|\" out.sql  # depending on what distribution you are using. Or, edit engines.txt and run generator.sh again"
fi
