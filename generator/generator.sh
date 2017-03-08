#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# ====== User Variables
MYSQL_VERSION=57     # Valid options: 56, 57
THREADS=4            # Number of SQL generation threads (default:4). Do not set the default >4 as pquery-run.sh also uses this script (avoids server overload with multiple runs)
SHEDULING_ENABLED=0  # On/Off (1/0). Enables/disables using mysql EVENTs .When using this, please note that testcases need to be reduced using PQUERY_MULTI=1 in reducer.sh (as they are effectively multi-threaded due to sheduler threads), and that issue reproducibility may be significantly lower (sheduling may not match original OS slicing, other running queries etc.). Still, using PQUERY_MULTI=1 a good number of issues are likely reproducibile and thus reducable given reducer.sh's random replay functionality.

# ====== Notes
# * The many backticks used in this script are not SQL/MySQL column-surrounding backticks, but rather subshells which call a function, for example `table` calls table()
# * To debug the syntax of generated SQL, use a set of commands like these:
#   $ ./bin/mysql -A -uroot -S${PWD}/socket.sock --force --binary-mode test < ~/percona-qa/generator/out.sql > ${PWD}/mysql.out 2>&1; grep "You have an error in your SQL syntax" mysql.out
#   There may be other errors then the ones shown here (see full mysql.out output), but this will highlight the main SQL syntax errors
#   The syntax failure raite should be well below 1 in 50 statements, and most of those should be due to semi-unfixable logic issues

# ====== Internal variables; do not modify
START=`date +%s`
RANDOM=`date +%s%N | cut -b13-19`  # Random entropy pool init
MYSQL_VERSION="$(echo "${MYSQL_VERSION}" | sed "s|\.||")"
SUBWHEREACTIVE=0

if [ "" == "$1" -o "$2" != "" ]; then
  echo "Please specify the number of queries to generate as the first (and only) option to this script"
  exit 1
else
  QUERIES=$1
fi

# ====== Check all needed data files are present
if [ ! -r tables.txt ]; then echo "Assert: tables.txt not found!"; exit 1; fi
if [ ! -r views.txt ]; then echo "Assert: views.txt not found!"; exit 1; fi
if [ ! -r pk.txt ]; then echo "Assert: pk.txt not found!"; exit 1; fi
if [ ! -r types.txt ]; then echo "Assert: types.txt not found!"; exit 1; fi
if [ ! -r data.txt ]; then echo "Assert: data.txt not found!"; exit 1; fi
if [ ! -r engines.txt ]; then echo "Assert: engines.txt not found!"; exit 1; fi
if [ ! -r a-z.txt ]; then echo "Assert: a-z.txt not found!"; exit 1; fi
if [ ! -r 0-6.txt ]; then echo "Assert: 0-6.txt not found!"; exit 1; fi
if [ ! -r 0-9.txt ]; then echo "Assert: 0-9.txt not found!"; exit 1; fi
if [ ! -r 1-3.txt ]; then echo "Assert: 1-3.txt not found!"; exit 1; fi
if [ ! -r 1-10.txt ]; then echo "Assert: 1-10.txt not found!"; exit 1; fi
if [ ! -r 1-100.txt ]; then echo "Assert: 1-100.txt not found!"; exit 1; fi
if [ ! -r 1-1000.txt ]; then echo "Assert: 1-1000.txt not found!"; exit 1; fi
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
if [ ! -r timefunc.txt ]; then echo "Assert: timefunc.txt not found!"; exit 1; fi
if [ ! -r timezone.txt ]; then echo "Assert: timezone.txt not found!"; exit 1; fi
if [ ! -r timeunit.txt ]; then echo "Assert: timeunit.txt not found!"; exit 1; fi
if [ ! -r func.txt ]; then echo "Assert: func.txt not found!"; exit 1; fi
if [ ! -r proc.txt ]; then echo "Assert: proc.txt not found!"; exit 1; fi
if [ ! -r trigger.txt ]; then echo "Assert: trigger.txt not found!"; exit 1; fi
if [ ! -r users.txt ]; then echo "Assert: users.txt not found!"; exit 1; fi
if [ ! -r profiletypes.txt ]; then echo "Assert: profiletypes.txt not found!"; exit 1; fi
if [ ! -r intervals.txt ]; then echo "Assert: intervals.txt not found!"; exit 1; fi
if [ ! -r lctimenames.txt ]; then echo "Assert: lctimenames.txt not found!"; exit 1; fi
if [ ! -r character.txt ]; then echo "Assert: character.txt not found!"; exit 1; fi
if [ ! -r numsimple.txt ]; then echo "Assert: numsimple.txt not found!"; exit 1; fi
if [ ! -r numeric.txt ]; then echo "Assert: numeric.txt not found!"; exit 1; fi
if [ ! -r aggregate.txt ]; then echo "Assert: aggregate.txt not found!"; exit 1; fi
if [ ! -r month.txt ]; then echo "Assert: month.txt not found!"; exit 1; fi
if [ ! -r day.txt ]; then echo "Assert: day.txt not found!"; exit 1; fi
if [ ! -r hour.txt ]; then echo "Assert: hour.txt not found!"; exit 1; fi
if [ ! -r minsec.txt ]; then echo "Assert: minsec.txt not found!"; exit 1; fi

# ====== Read data files into arrays                                            # ====== Usable functions to read from those arrays
mapfile -t tables    < tables.txt       ; TABLES=${#tables[*]}                  ; table()      { echo "${tables[$[$RANDOM % $TABLES]]}"; }
mapfile -t views     < views.txt        ; VIEWS=${#views[*]}                    ; view()       { echo "${views[$[$RANDOM % $VIEWS]]}"; }
mapfile -t pk        < pk.txt           ; PK=${#pk[*]}                          ; pk()         { echo "${pk[$[$RANDOM % $PK]]}"; }
mapfile -t types     < types.txt        ; TYPES=${#types[*]}                    ; ctype()      { echo "${types[$[$RANDOM % $TYPES]]}"; }
mapfile -t datafile  < data.txt         ; DATAFILE=${#datafile[*]}              ; datafile()   { echo "${datafile[$[$RANDOM % $DATAFILE]]}"; }
mapfile -t engines   < engines.txt      ; ENGINES=${#engines[*]}                ; engine()     { echo "${engines[$[$RANDOM % $ENGINES]]}"; }
mapfile -t az        < a-z.txt          ; AZ=${#az[*]}                          ; az()         { echo "${az[$[$RANDOM % $AZ]]}"; }
mapfile -t n9        < 0-9.txt          ; N9=${#n9[*]}                          ; n9()         { echo "${n9[$[$RANDOM % $N9]]}"; }
mapfile -t n3        < 1-3.txt          ; N3=${#n3[*]}                          ; n3()         { echo "${n3[$[$RANDOM % $N3]]}"; }
mapfile -t n6        < 1-6.txt          ; N6=${#n6[*]}                          ; n6()         { echo "${n6[$[$RANDOM % $N6]]}"; }
mapfile -t n10       < 1-10.txt         ; N10=${#n10[*]}                        ; n10()        { echo "${n10[$[$RANDOM % $N10]]}"; }
mapfile -t n100      < 1-100.txt        ; N100=${#n100[*]}                      ; n100()       { echo "${n100[$[$RANDOM % $N100]]}"; }
mapfile -t n1000     < 1-1000.txt       ; N1000=${#n1000[*]}                    ; n1000()      { echo "${n1000[$[$RANDOM % $N1000]]}"; }
mapfile -t nn1000    < n1000-1000.txt   ; NN1000=${#nn1000[*]}                  ; nn1000()     { echo "${nn1000[$[$RANDOM % $NN1000]]}"; }
mapfile -t flush     < flush.txt        ; FLUSH=${#flush[*]}                    ; flush()      { echo "${flush[$[$RANDOM % $FLUSH]]}"; }
mapfile -t lock      < lock.txt         ; LOCK=${#lock[*]}                      ; lock()       { echo "${lock[$[$RANDOM % $LOCK]]}"; }
mapfile -t reset     < reset.txt        ; RESET=${#reset[*]}                    ; reset()      { echo "${reset[$[$RANDOM % $RESET]]}"; }
mapfile -t charcol   < charsetcol_$MYSQL_VERSION.txt; CHARCOL=${#charcol[*]}    ; charcol()    { echo "${charcol[$[$RANDOM % $CHARCOL]]}"; }
mapfile -t setvars   < session_$MYSQL_VERSION.txt   ; SETVARS=${#setvars[*]}    ; setvars()    { echo "${setvars[$[$RANDOM % $SETVARS]]}"; }   # S(ession)
mapfile -t setvarg   < global_$MYSQL_VERSION.txt    ; SETVARG=${#setvarg[*]}    ; setvarg()    { echo "${setvarg[$[$RANDOM % $SETVARG]]}"; }   # G(lobal)
mapfile -t pstables  < pstables_$MYSQL_VERSION.txt  ; PSTABLES=${#pstables[*]}  ; pstable()    { echo "${pstables[$[$RANDOM % $PSTABLES]]}"; }
mapfile -t setvals   < setvalues.txt    ; SETVALUES=${#setvals[*]}              ; setval()     { echo "${setvals[$[$RANDOM % $SETVALUES]]}"; }
mapfile -t sqlmode   < sqlmode.txt      ; SQLMODE=${#sqlmode[*]}                ; sqlmode()    { echo "${sqlmode[$[$RANDOM % $SQLMODE]]}"; }
mapfile -t optsw     < optimizersw.txt  ; OPTSW=${#optsw[*]}                    ; optsw()      { echo "${optsw[$[$RANDOM % $OPTSW]]}"; }
mapfile -t inmetrics < inmetrics.txt    ; INMETRICS=${#inmetrics[*]}            ; inmetrics()  { echo "${inmetrics[$[$RANDOM % $INMETRICS]]}"; }
mapfile -t event     < event.txt        ; EVENT=${#event[*]}                    ; event()      { echo "${event[$[$RANDOM % $EVENT]]}"; }
mapfile -t timefunc  < timefunc.txt     ; TIMEFUNC=${#timefunc[*]}              ; timefuncpr() { echo "${timefunc[$[$RANDOM % $TIMEFUNC]]}"; }  # pr: prepare
mapfile -t timezone  < timezone.txt     ; TIMEZONE=${#timezone[*]}              ; timezone()   { echo "${timezone[$[$RANDOM % $TIMEZONE]]}"; }
mapfile -t timeunit  < timeunit.txt     ; TIMEUNIT=${#timeunit[*]}              ; timeunit()   { echo "${timeunit[$[$RANDOM % $TIMEUNIT]]}"; }
mapfile -t func      < func.txt         ; FUNC=${#func[*]}                      ; func()       { echo "${func[$[$RANDOM % $FUNC]]}"; }
mapfile -t proc      < proc.txt         ; PROC=${#proc[*]}                      ; proc()       { echo "${proc[$[$RANDOM % $PROC]]}"; }
mapfile -t trigger   < trigger.txt      ; TRIGGER=${#trigger[*]}                ; trigger()    { echo "${trigger[$[$RANDOM % $TRIGGER]]}"; }
mapfile -t users     < users.txt        ; USERS=${#users[*]}                    ; user()       { echo "${users[$[$RANDOM % $USERS]]}"; }
mapfile -t proftypes < profiletypes.txt ; PROFTYPES=${#proftypes[*]}            ; proftype()   { echo "${proftypes[$[$RANDOM % $PROFTYPES]]}"; }
mapfile -t intervals < intervals.txt    ; INTERVALS=${#intervals[*]}            ; intervalpr() { echo "${intervals[$[$RANDOM % $INTERVALS]]}"; }  # pr: prepare
mapfile -t lctimenms < lctimenames.txt  ; LCTIMENMS=${#lctimenms[*]}            ; lctimename() { echo "${lctimenms[$[$RANDOM % $LCTIMENMS]]}"; }
mapfile -t character < character.txt    ; CHARACTER=${#character[*]}            ; character()  { echo "${character[$[$RANDOM % $CHARACTER]]}"; }
mapfile -t numsimple < numsimple.txt    ; NUMSIMPLE=${#numsimple[*]}            ; numsimple()  { echo "${numsimple[$[$RANDOM % $NUMSIMPLE]]}"; }
mapfile -t numeric   < numeric.txt      ; NUMERIC=${#numeric[*]}                ; numeric()    { echo "${numeric[$[$RANDOM % $NUMERIC]]}"; }
mapfile -t aggregate < aggregate.txt    ; AGGREGATE=${#aggregate[*]}            ; aggregate()  { echo "${aggregate[$[$RANDOM % $AGGREGATE]]}"; }
mapfile -t month     < month.txt        ; MONTH=${#month[*]}                    ; month()      { echo "${month[$[$RANDOM % $MONTH]]}"; }
mapfile -t day       < day.txt          ; DAY=${#day[*]}                        ; day()        { echo "${day[$[$RANDOM % $DAY]]}"; }
mapfile -t hour      < hour.txt         ; HOUR=${#hour[*]}                      ; hour()       { echo "${hour[$[$RANDOM % $HOUR]]}"; }
mapfile -t minsec    < minsec.txt       ; MINSEC=${#minsec[*]}                  ; minsec()     { echo "${minsec[$[$RANDOM % $MINSEC]]}"; }

if [ ${TABLES} -lt 2 ]; then echo "Assert: number of table names is less then 2. A minimum of two tables is required for proper operation. Please ensure tables.txt has at least two table names"; exit 1; fi

# Bash requires functions to be defined ABOVE the line from which they are called. This would normally mean that we have to watch the order in which we define and call functions, which would be complex. For example, `data` calls other functions and those functions in turn may loop back to `data` (i.e. normally impossible to code). However, here we declare all functions first, and only then start calling them towards the end of the script which is fine/works, even if functions are looping or are declared BELOW the line from which they are callled (remember the main call is at the end of the script and all functions are allready "read". Ref handy_gnu.txt
# ========================================= Single, fixed
alias2()     { echo "a`n2`"; }
alias3()     { echo "a`n3`"; }
asalias2()   { echo "AS a`n2`"; }
asalias3()   { echo "AS a`n3`"; }
numericop()  { echo "`numeric`" | sed "s|DUMMY|`danrorfull`|;s|DUMMY2|`danrorfull`|;s|DUMMY3|`danrorfull`|"; }  # NUMERIC FUNCTION with data (includes numbers) or -1000 to 1000 as options, for example ABS(nr)
joinlron()   { echo "`leftright` `outer` JOIN"; }
joinlronla() { echo "`natural` `leftright` `outer` JOIN"; }
interval()   { echo "`intervalpr`" | sed "s|DUMMY|`neg``dataornum2`|;s|DUMMY|`neg``dataornum2`|;s|DUMMY|`neg``dataornum2`|;s|DUMMY|`neg``dataornum2`|;s|DUMMY|`neg``dataornum2`|" }
intervaln()  { echo "INTERVAL `interval`"; }
dategenpr()  { echo "`n9``n9``n9``n9`-`month`-`day` `hour`:`minsec`:`minsec`"; }
timefunc()   { echo "`timefuncpr`" | sed "s|DUMMY_DATE|`dategen`|;s|DUMMY_DATE|`dategen`|g;s|DUMMY_NR|`dataornum2`|;s|DUMMY_NR|`dataornum2`|;s|DUMMY_NR|`dataornum2`|g;s|DUMMY_INTERVAL|`intervaln`|;s|DUMMY_TIMEZONE|`timezone`|;s|DUMMY_TIMEZONE|`timezone`|g;s|DUMMY_N6|`n6`|g;s|DUMMY_DATA|`data`|g;s|DUMMY_UNIT|`timeunit`|g"; }
timefunccol(){ echo "`timefuncpr`" | sed "s|DUMMY_DATE|c`n3`|;s|DUMMY_DATE|c`n3`|g;s|DUMMY_NR|`dataornum2`|;s|DUMMY_NR|`dataornum2`|;s|DUMMY_NR|`dataornum2`|g;s|DUMMY_INTERVAL|`intervaln`|;s|DUMMY_TIMEZONE|`timezone`|;s|DUMMY_TIMEZONE|`timezone`|g;s|DUMMY_N6|`n6`|g;s|DUMMY_DATA|`data`|g;s|DUMMY_UNIT|`timeunit`|g"; }
partnum()    { echo "PARTITIONS `n1000`"; }  
partnumsub() { echo "SUBPARTITIONS `n1000`"; }
partdef1()   { INC1=0; echo "(`partdef1b`)"; }
partdef2()   { INC1=0; INC2=0; echo "(`partdef2b`)"; }
partdef3()   { INC1=0; echo "(`partdef3b`)"; }
partdef4()   { INC1=0; INC2=0; echo "(`partdef4b`)"; }
partdef1b()  { INC1=$[ $INC1 + $[ $RANDOM % 100 + 1 ] ]; echo "PARTITION p${INC1} VALUES LESS THAN (${INC1}) `partse` `partcomment` `partmax` `partmin` `partdefar1`"; }
partdef2b()  { INC1=$[ $INC1 + $[ $RANDOM % 100 + 1 ] ]; INC2=$[ $INC2 + $[ $RANDOM % 100 + 1 ] ]; echo "PARTITION p${INC1} VALUES LESS THAN (${INC1},${INC2}) `partse` `partcomment` `partmax` `partmin` `partdefar2`"; }
partdef3b()  { INC1=$[ $INC1 + 5 + $[ $RANDOM % 10 + 1 ] ]; echo "PARTITION p${INC1} VALUES IN (${INC1},$[ ${INC1} + 1 ],$[ ${INC1} + 2 ],$[ ${INC1} + 3 ],$[ ${INC1} + 4 ],$[ ${INC1} + 5 ]) `partse` `partcomment` `partmax` `partmin` `partdefar3`"; }
partdef4b()  { INC1=$[ $INC1 + 5 + $[ $RANDOM % 10 + 1 ] ]; INC2=$[ $INC2 + 5 + $[ $RANDOM % 10 + 1 ] ]; echo "PARTITION p${INC1} VALUES IN ((${INC1},${INC2}),($[ ${INC1} + 1 ],$[ ${INC2} + 1 ]),($[ ${INC1} + 2 ],$[ ${INC2} + 2 ]),($[ ${INC1} + 3 ],$[ ${INC2} + 3 ]),($[ ${INC1} + 4 ],$[ ${INC2} + 4 ]),($[ ${INC1} + 5 ],$[ ${INC2} + 5 ])) `partse` `partcomment` `partmax` `partmin` `partdefar4`"; }
parthash()   { echo "`linear` HASH(`collist1`) `partnum`"; }
partkey()    { echo "`linear` KEY `algorithm` (`collist1`) `partnum`"; }
# ========================================= Single, random
neg()        { if [ $[$RANDOM % 20 + 1] -le 1  ]; then echo "-"; fi }                            #  5% - (negative number)
storage()    { if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "STORAGE"; fi }                      # 15% STORAGE
temp()       { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "TEMPORARY "; fi }                   # 20% TEMPORARY
ignore()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "IGNORE"; fi }                       # 20% IGNORE
linear()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LINEAR"; fi }                       # 50% LINEAR
lowprio()    { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "LOW_PRIORITY"; fi }                 # 25% LOW_PRIORITY
quick()      { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "QUICK"; fi }                        # 20% QUICK
limit()      { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `n9`"; fi }                   # 50% LIMIT 0-9
limoffset()  { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "`n3`,"; fi }                        # 10% 0-3 offset (for LIMITs)
ofslimit()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIMIT `limoffset``n9`"; fi }        # 50% LIMIT 0-9, with potential offset
natural()    { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "NATURAL"; fi }                      # 10% NATURAL (for JOINs) (NATURAL may cause queries with >2 tables to fail ref http://dev.mysql.com/doc/refman/5.7/en/join.html)
outer()      { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "OUTER"; fi }                        # 40% OUTER (for JOINs)
partition()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "PARTITION p`n3`"; fi }              # 20% PARTITION p1-3
partitionby(){ if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "PARTITION BY `partdecl`"; fi }      # 25% PARTITION BY
partse()     { if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "`storage` ENGINE`equals``engine`" ; fi }  # 15% ENGINE (for partitioning)
partcomment(){ if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "COMMENT`equals``data`"; fi }        # 10% COMMENT (for partitioning)
partmax()    { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "MAX_ROWS`equals``n1000`"; fi }      # 10% MAX_ROWS (for partitioning)
partmin()    { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "MIN_ROWS`equals``n1000`"; fi }      # 10% MIN_ROWS (for partitioning)
full()       { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "FULL"; fi }                         # 20% FULL
not()        { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "NOT"; fi }                          # 25% NOT
no()         { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "NO"; fi }                           # 40% NO (for transactions)
fromdb()     { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "FROM test"; fi }                    # 10% FROM test
offset()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "OFFSET `n9`"; fi }                  # 20% OFFSET 0-9
forquery()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "FORQUERY `n9`"; fi }                # 20% QUERY 0-9
onephase()   { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "ONE PHASE"; fi }                    # 80% ONE PHASE (needs to be high ref http://dev.mysql.com/doc/refman/5.7/en/xa-states.html)
convertxid() { if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "CONVERT XID"; fi }                  # 15% CONVERT XID
ifnotexist() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IF NOT EXISTS"; fi }                # 50% IF NOT EXISTS
ifexist()    { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IF EXISTS"; fi }                    # 50% IF EXISTS
completion() { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "ON COMPLETION `not` PRESERVE"; fi } # 25% ON COMPLETION [NOT] PRESERVE
comment()    { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "COMMENT '$(echo "`data`" | sed "s|'||g")'"; fi }  # 25% COMMENT
intervaladd(){ if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "+ INTERVAL `interval`"              # 20% + 0-9 INTERVAL
work()       { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "WORK"; fi }                         # 25% WORK (for transactions and savepoints)
savepoint()  { if [ $[$RANDOM % 20 + 1] -le 5  ]; then echo "SAVEPOINT"; fi }                    # 25% SAVEPOINT (for savepoints)
chain()      { if [ $[$RANDOM % 20 + 1] -le 7  ]; then echo "AND `no` CHAIN"; fi }               # 35% AND [NO] CHAIN (for transactions)
release()    { if [ $[$RANDOM % 20 + 1] -le 7  ]; then echo "NO RELEASE"; fi }                   # 35% NO RELEASE (for transactions). Plain 'RELEASE' is not possible, as this drops client connection
quick()      { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "QUICK"; fi }                        # 20% QUICK
extended()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "EXTENDED"; fi }                     # 20% EXTENDED
usefrm()     { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "USE_FRM"; fi }                      # 20% USE_FRM
localonly()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LOCAL"; fi }                        # 50% LOCAL (note 'local' is system keyword, hence 'localonly')
# ========================================= Dual
onoff()      { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "ON"; else echo "OFF"; fi }                    # 75% ON, 25% OFF
onoff01()    { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "1"; else echo "0"; fi }                       # 75% 1 (on), 25% 0 (off)
equals()     { if [ $[$RANDOM % 20 + 1] -le 3  ]; then echo "="; else echo " "; fi }                       # 15% =, 85% space
allor1()     { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "*"; else echo "1"; fi }                       # 80% *, 20% 1
startsends() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "STARTS"; else echo "ENDS"; fi }               # 50% STARTS, 50% ENDS
globses()    { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi }            # 50% GLOBAL, 50% SESSION
andor()      { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AND"; else echo "OR"; fi }                    # 50% AND, 50% OR
leftright()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LEFT"; else echo "RIGHT"; fi }                # 50% LEFT, 50% RIGHT (for JOINs)
xid()        { if [ $[$RANDOM % 20 + 1] -le 15 ]; then echo "'xid1'"; else echo "'xid2'"; fi }             # 75% xid1, 25% xid2
disenable()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ENABLE"; else echo "DISABLE"; fi }            # 50% ENABLE, 50% DISABLE
sdisenable() { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "`disenable`"; else echo "DISABLE ON SLAVE"; fi }  # 40% ENABLE, 40% DISALBE, 20% DISABLE ON SLAVE
schedule()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "AT `timestamp` `intervaladd`"; else echo "EVERY `interval` `opstend`"; fi }  # 50% AT, 50% EVERY (for EVENTs)
readwrite()  { if [ $[$RANDOM % 30 + 1] -le 10 ]; then echo 'READ ONLY'; else echo 'READ WRITE'; fi }      # 50% READ ONLY, 50% WRITE ONLY (for START TRANSACTION)
binmaster()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "BINARY"; else echo "MASTER"; fi }             # 50% BINARY, 50% MASTER
nowblocal()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NO_WRITE_TO_BINLOG"; else echo "LOCAL"; fi }  # 50% NO_WRITE_TO_BINLOG, 50% LOCAL
locktype()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ `localonly`"; else echo "`lowprio` WRITE"; fi }  # 50% READ [LOCAL], 50% [LOW_PRIORITY] WRITE
charactert() { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "`character` `charactert`"; else echo "`character`"; fi }  # 40% NESTED CHARACTERISTIC, 60% SINGLE (OR FINAL) CHARACTERISTIC (increasing final possibility)
danrorfull() { if [ $[$RANDOM % 20 + 1] -le 19 ]; then echo "`dataornum`"; else echo "`fullnrfunc`"; fi }  # 95% data (inc numbers) or -1000 to 1000, 5% nested full nr function (MAX 10% to avoid inf loop)
numericadd() { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "`numsimple` `eitherornn` `numericadd`"; else echo "`numsimple` `eitherornn`" ; fi }  # 40% NESTED +/-/etc. NR FUNCTION() OR SIMPLE, 60% SINGLE (OR FINAL) +/-/etc. as above
dataornum()  { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "`data`"; else echo "`nn1000`"; fi }           # 20% data (inc numbers), 80% -1000 to 1000
dataornum2() { if [ $[$RANDOM % 20 + 1] -le 2  ]; then echo "`data`"; else echo "`n100`"; fi }             # 10% data (inc numbers), 90% 0 to 100
eitherornn() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`dataornum`"; else echo "`numericop`"; fi }   # 50% data (inc numbers), 50% NUMERIC FUNCTION() like ABS(nr) etc.
fullnrfunc() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`eitherornn` `numsimple` `eitherornn`"; else echo "`eitherornn` `numsimple` `eitherornn` `numericadd`"; fi }  # 50% full numeric function, 50% idem with nesting
aggregated() { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "`aggregate`" | sed "s|DUMMY|`data`|"; else echo "`aggregate`" | sed "s|DUMMY|`danrorfull`|"; fi }  # 80% AGGREGATE FUNCTION with data, 20% with numbers or full function (for use inside a SELECT ... query)
aggregatec() { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "`aggregate`" | sed "s|DUMMY|c`n3`|"; else echo "`aggregate`" | sed "s|DUMMY|`aggregated`|"; fi }  # 80% AGGREGATE FUNCTION using a column, 20% with data, numbers or full function (for use inside a SELECT ... FROM ... query)
azn9()       { if [ $[$RANDOM % 36 + 1] -le 26 ]; then echo "`az`"; else echo "`n9`"; fi }  # 26 Letters, 10 digits, equal total division => 1 random character a-z or 0-9
dategen()    { if [ $[$RANDOM % 20 + 1] -le 19 ]; then echo "`dategenpr`"; else echo "`timefuncpr`"; fi }  # 95% generated date, 5% interval (MAX 10% to avoid inf loop)
# ========================================= Triple
subpart()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "SUBPARTITION BY `linear` HASH(`collist2`) `partnumsub`"; else echo "SUBPARTITION BY `linear` KEY `algorithm` (`collist2`) `partnumsub`"; fi; fi }  # 10% SUBPARTITION BY HASH, 10% SUBPARTITION BY KEY, 80% EMPTY/NOTHING
partdefar1() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo ", `partdef1b`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ", PARTITION pMAX VALUES LESS THAN MAXVALUE `partse` `partcomment` `partmax` `partmin`"; fi; fi }  # 20% partdef1b, 40% MAXVALUE parition, 40% EMPTY/NOTHING
partdefar2() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo ", `partdef2b`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ", PARTITION pMAX VALUES LESS THAN (MAXVALUE,MAXVALUE) `partse` `partcomment` `partmax` `partmin`"; fi; fi }  # 20% partdef2b, 40% MAXVALUE parition, 40% EMPTY/NOTHING
partdefar3() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo ", `partdef3b`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ", PARTITION pNEG VALUES IN (-1,-2,-3,-4,-5) `partse` `partcomment` `partmax` `partmin`"; fi; fi }  # 20% partdef3b, 40% some negative values parition, 40% EMPTY/NOTHING
partdefar4() { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo ", `partdef4b`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ", PARTITION pNEG VALUES IN ((NULL,NULL),(-2,-2),(-3,-3),(-4,-4),(-5,-5)) `partse` `partcomment` `partmax` `partmin`"; fi; fi }  # 20% partdef4b, 40% some NULL/negative values parition, 40% EMPTY/NOTHING
data()       { if [ $[$RANDOM % 20 + 1] -le 16 ]; then echo "`datafile`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`timefunc`"; else echo "(`fullnrfunc`) `numsimple` (`fullnrfunc`)"; fi; fi }  # 80% data from data.txt file, 10% date/time function data from timefunc.txt, 10% generated full numerical function
ac()         { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "a"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "b"; else echo "c"; fi; fi }  # 40% a, 30% b, 30% c
algorithm()  { if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ALGORITHM=1"; else echo "ALGORITHM=2"; fi; fi }  # 15% ALGORITHM=1, ALGORITHM=2, 70% EMPTY/NOTHING
trxopt()     { if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`readwrite`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "WITH CONSISTENT SNAPSHOT, `readwrite`"; else echo "WITH CONSISTENT SNAPSHOT"; fi; fi }  # 50% R/W or R/O, 25% WITH C/S + R/W or R/O, 25% C/S
definer()    { if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "DEFINER=`user`"; else echo "DEFINER=CURRENT_USER"; fi; fi }  # 15% DEFINER=random user, 15% DEFINER=CURRENT USER, 70% EMPTY/NOTHING
suspendfm()  { if [ $[$RANDOM % 20 + 1] -le 2  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "SUSPEND"; else echo "SUSPEND FOR MIGRATE"; fi; fi }  # 5% SUSPEND, 5% SUSPEND FOR MIGRATE, 90% EMPTY/NOTHING (needs to be low, ref url above)
joinresume() { if [ $[$RANDOM % 20 + 1] -le 6  ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "JOIN"; else echo "RESUME"; fi; fi }  # 15% JOIN, 15% RESUME, 70% EMPTY/NOTHING
emglobses()  { if [ $[$RANDOM % 20 + 1] -le 14 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "GLOBAL"; else echo "SESSION"; fi; fi }  # 35% GLOBAL, 35% SESSION, 30% EMPTY/NOTHING
emascdesc()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "ASC"; else echo "DESC"; fi; fi }  # 25% ASC, 25% DESC, 50% EMPTY/NOTHING
bincharco()  { if [ $[$RANDOM % 30 + 1] -le 10 ]; then echo 'CHARACTER SET "Binary" COLLATE "Binary"'; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo 'CHARACTER SET "utf8" COLLATE "utf8_bin"'; else echo 'CHARACTER SET "latin1" COLLATE "latin1_bin"'; fi; fi }   # 33% Binary/Binary, 33% utf8/utf8_bin, 33% latin1/latin1_bin
inout()      { if [ $[$RANDOM % 20 + 1] -le 8  ]; then echo "INOUT"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "IN"; else echo "OUT"; fi; fi }  # 40% INOUT, 30% IN, 30% OUT
nowriteloc() { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NO_WRITE_TO_BINLOG"; else echo "LOCAL"; fi; fi }  # 25% NO_WRITE_TO_BINLOG, 25% LOCAL, 50% EMPTY/NOTHING
partrange()   { if [ $[$RANDOM % 20 + 1] -le 7  ]; then echo "RANGE(c`n3`) `partdef1`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "RANGE(c`n3`) `subpart` `partdef1`"; else echo "RANGE COLUMNS(`collist2`) `partdef2`"; fi; fi }  # 35% RANGE(col), 33% RANGE(col) w/ subpart, 33% RANGE COLUMNS(col)
partlist()    { if [ $[$RANDOM % 20 + 1] -le 7  ]; then echo "LIST(c`n3`) `partdef3`"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIST(c`n3`) `subpart` `partdef3`"; else echo "LIST COLUMNS(`collist2`) `partdef4`"; fi; fi }  # 35% LIST(col), 33% LIST(col) w/ subpart, 33% LIST COLUMNS(col)
# ========================================= Quadruple
collist1()   { if [ $[$RANDOM % 20 + 1] -le 8  ]; then if [ $[$RANDOM % 20 + 1] -le 12 ]; then echo "(c`n3`)"; else echo "(c`n3`,c`n3`)"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "(c1,c2)"; else echo "(c3,c1)"; fi; fi }  # 24% random single column, 16% random dual column (may fail), 30% (c1,c2), 30% (c3,c1)
collist2()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "(c1,c2)"; else echo "(c2,c3)"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "(c1,c3)"; else echo "(c3,c1)"; fi; fi }  # 25% (c1,c2), 25% (c2,c3), 25% (c1,c3), 25% (c3,c1)
like()       { if [ $[$RANDOM % 20 + 1] -le 8  ]; then if [ $[$RANDOM % 20 + 1] -le 5 ]; then echo "LIKE '`azn9`'"; else echo "LIKE '`azn9`%'"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "LIKE '%`azn9`'"; else echo "LIKE '%`azn9`%'"; fi; fi; }  # 10% LIKE '<char>', 30% LIKE '<char>%', 30% LIKE '%<char>', 30% LIKE '%<char>%'
isolation()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ COMMITTED"; else echo "REPEATABLE READ"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "READ UNCOMMITTED"; else echo "SERIALIZABLE"; fi; fi; }  # 25% READ COMMITTED, 25% REPEATABLE READ, 25% READ UNCOMMITTED, 25% SERIALIZABLE
timestamp()  { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "CURRENT_TIMESTAMP"; else echo "CURRENT_TIMESTAMP()"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NOW()"; else echo "`data`"; fi; fi; }  # 25% CURRENT_TIMESTAMP, 25% CURRENT_TIMESTAMP(), 25% NOW(), 25% random data
partdecl()   { if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`parthash`"; else echo "`partkey`"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "`partrange`"; else echo "`partlist`"; fi; fi; }  # Partitioning: 25% HASH, 25% KEY, 25% RANGE (split further), 25% LIST (split furter)
# ========================================= Quintuple
operator()   { if [ $[$RANDOM % 20 + 1] -le 8 ]; then echo "="; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo ">"; else echo ">="; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "<"; else echo "<="; fi; fi; fi; }  # 40% =, 15% >, 15% >=, 15% <, 15% <=
pstimer()    { if [ $[$RANDOM % 20 + 1] -le 4 ]; then echo "idle"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "wait"; else echo "stage"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "statement"; else echo "statement"; fi; fi; fi; }  # 20% idle, 20% wait, 20% stage, 20% statement, 20% statement
pstimernm()  { if [ $[$RANDOM % 20 + 1] -le 4 ]; then echo "CYCLE"; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "NANOSECOND"; else echo "MICROSECOND"; fi; else if [ $[$RANDOM % 20 + 1] -le 10 ]; then echo "MILLISECOND"; else echo "TICK"; fi; fi; fi; }  # 20% CYCLE, 20% NANOSECOND, 20% MICROSECOND, 20% MILLISECOND, 20% TICK
# ========================================= Subcalls
subwhact()   { if [ ${SUBWHEREACTIVE} -eq 0 ]; then echo "WHERE "; fi }  # Only use 'WHERE' if this is not a sub-WHERE, i.e. a call from subwhere()
subwhere()   { SUBWHEREACTIVE=1; if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "`andor` `whereal`"; fi; }  # 20% sub-WHERE (additional and/or WHERE clause)
subordby()   { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo ",c`n3` `emascdesc`"; fi }                    # 20% sub-ORDER BY (additional ORDER BY column)
# ========================================= Special/Complex
opstend()    { if [ $[$RANDOM % 20 + 1] -le 4  ]; then echo "`startsends` `timestamp` `intervaladd`"; fi } # 20% optional START/STOP (for EVENTs)
where()      { echo "`whereal`" | sed "s|a[0-9]\+\.||g"; }             # where():    e.g. WHERE    c1==c2    etc. (not suitable for multi-table WHERE's with similar column names)
wheretbl()   { echo "`where`" | sed "s|\(c[0-9]\+\)|`table`.\1|g"; }   # wheretbl(): e.g. WHERE t1.c1==t2.c2 etc. (may mismatch on table names if many or few tables are used)
whereal()    {                                                         # whereal():  e.g. WHERE a1.c1==a2.c2 etc. (requires table aliases to be in place)
  WHERE_RND=4; if [ ${SUBWHEREACTIVE} -eq 1 ]; then WHERE_RND=2; fi    # When generating a sub-WHERE, we need to generate a new clause, not an empty "No WHERE clause", as this would lead to an invalid syntax like "WHERE ... AND <nothing>"
  case $[$RANDOM % $WHERE_RND + 1] in
    1) echo "`subwhact``alias3`.c`n3``operator``data` `subwhere`";;    # `subwhact`: sub-WHERE active or not, ref subwhact(). Ensures 'WHERE' is not repeated in sub-WHERE's (WHERE x=y AND a=b should not repeat WHERE for a=b)
    2) echo "`subwhact``alias3`.c`n3``operator``alias3`.c`n3` `subwhere`";;
[3-4]) ;;  # 50% No WHERE clause
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
  case $[$RANDOM % 5 + 1] in
    1) echo ",";;
    2) echo "JOIN";;
    3) echo "INNER JOIN";;
    4) echo "CROSS JOIN";;
    5) echo "STRAIGHT_JOIN";;
    *) echo "Assert: invalid random case selection in join() case";;
  esac
}
lastjoin()  {
  LASTJOIN=`join`
  if [ "${LASTJOIN}" == "JOIN" ]; then echo "`natural` JOIN"; else echo "${LASTJOIN}"; fi
}
selectq()   {  # Select Query. Do not use 'select' as select is a reserved system command, use 'selectq' instead
  case $[$RANDOM % 10 + 1] in  # Select (needs further work: JOIN syntax + SELECT options)
    1) echo "SELECT * FROM `table`";;
    2) echo "SELECT `aggregatec` FROM `table`";;  # Aggregate function with a column, data, or numerical function for example SELECT COUNT(c1) FROM t1 or the same with BIT_OR(4+3)
    3) echo "SELECT `aggregated`";;               # Aggregate function with data or a numerical function, for example BIT_OR(1) or SUM(5+1)
    4) case $[$RANDOM % 2 + 1] in                 # Subqueries
        1) echo "SELECT * FROM (`selectq`) AS a1";;
        2) echo "SELECT * FROM (`query`) AS a1";;
        *) echo "Assert: invalid random case selection in SELECT FROM (subquery) case";;
       esac;;
    5) echo "SELECT c`n3` FROM `table`";;
    6) echo "SELECT c`n3`,c`n3` FROM `table`";;
    7) echo "SELECT c`n3`,c`n3` FROM `table` AS a1 `lastjoin` `table` AS a2 `whereal`";;
    8) echo "SELECT c`n3` FROM `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
    9) case $[$RANDOM % 2 + 1] in
        1) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3` FROM ${FIXEDTABLE} `joinlronla` `table` ON ${FIXEDTABLE}.c`n3`";;
        2) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3` FROM `table` `joinlronla` ${FIXEDTABLE} ON ${FIXEDTABLE}.c`n3`";;
        *) echo "Assert: invalid random case selection in FIXEDTABLE1 join case";;
       esac;;
   10) case $[$RANDOM % 2 + 1] in
        1) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3` FROM ${FIXEDTABLE} `joinlronla` `table` ON ${FIXEDTABLE}.c`n3`=`data`";;
        2) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3` FROM `table` `joinlronla` ${FIXEDTABLE} ON ${FIXEDTABLE}.c`n3`=`data`";;
        *) echo "Assert: invalid random case selection in FIXEDTABLE2 join case";;
       esac;;
    #10) case $[$RANDOM % 3 + 1] in  # Needs fixing
    #    1) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3` FROM ${FIXEDTABLE} `joinlron` `table` `joinlronla` `table` USING (${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3`)";;
    #    2) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3` FROM `table` `joinlron` ${FIXEDTABLE} `joinlronla` `table` USING (${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3`)";;
    #    3) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3` FROM `table` `joinlron` `table` `joinlronla` ${FIXEDTABLE} USING (${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3`)";;
    #    *) echo "Assert: invalid random case selection in FIXEDTABLE4 join case";;
    #   esac;;
    #11) case $[$RANDOM % 2 + 1] in  # Needs fixing
    #    1) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3` FROM ${FIXEDTABLE} `joinlronla` `table` USING (${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3`)";;
    #    2) FIXEDTABLE="`table`"; echo "SELECT ${FIXEDTABLE}.c`n3` FROM `table` `joinlronla` ${FIXEDTABLE} USING (${FIXEDTABLE}.c`n3`,${FIXEDTABLE}.c`n3`)";;
    #    *) echo "Assert: invalid random case selection in FIXEDTABLE3 join case";;
    #   esac;;
    *) echo "Assert: invalid random case selection in SELECT case";;
  esac
}

query(){
  #FIXEDTABLE1=`table`  # A fixed table name: this can be used in queries where a unchanging table name is required to ensure the query works properly. For example, SELECT t1.c1 FROM t1;
  #FIXEDTABLE2=${FIXEDTABLE1}; while [ "${FIXEDTABLE1}" -eq "${FIXEDTABLE2}" ]; do FIXEDTABLE2=`table`; done  # A secondary fixed table, different from the first fixed table
  case $[$RANDOM % 39 + 1] in
    # Frequencies for CREATE (1-3), INSERT (4-7), and DROP (8) statements are well tuned, please do not change these case ranges
    # Most other statements have been frequency tuned also, but not to the same depth. If you find bugs (for example too many errors because of frequency), please fix them
    # Possible expansions for partitoning (partitioning tree starts down from `partionby`)
    # - Instead of `collist1` use, this can be expanded with timefunc, but need to swap DUMMY_DATE to columns + match CREATE TABLE columns to it
    # - These partdef (partitions+subpartitions) options were not added yet: [DATA DIRECTORY [=] 'data_dir'], [INDEX DIRECTORY [=] 'index_dir'], [TABLESPACE [=] tablespace_name]
    # - VALUES LESS THAN (ref partdef1b/partdef2b/partdefar1/partdefar2) can be expanded further with an expression instead of a static number
    # - Subpartioning support was added, but it can be reviewed and be extended, see https://dev.mysql.com/doc/refman/5.7/en/partitioning-subpartitions.html
    #   - Subpartion defenition (subpartition_definition in https://dev.mysql.com/doc/refman/5.7/en/create-table.html) needs to be added. Clauses (COMMENT= etc.) already added
    [1-3]) case $[$RANDOM % 6 + 1] in  # CREATE (needs further work)
        1) echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 `pk`,c2 `ctype`,c3 `ctype`) ENGINE=`engine` `partitionby`";;
        2) echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 `ctype`,c2 `ctype`,c3 `ctype`) ENGINE=`engine` `partitionby`";;
        3) C1TYPE=`ctype`
           if [ "`echo ${C1TYPE} | grep -o 'CHAR'`" == "CHAR" -o "`echo ${C1TYPE} | grep -o 'BLOB'`" == "BLOB" -o "`echo ${C1TYPE} | grep -o 'TEXT'`" == "TEXT" ]; then
             echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1(`n10`))) ENGINE=`engine` `partitionby`"
           else
             echo "CREATE `temp` TABLE `ifnotexist` `table` (c1 ${C1TYPE},c2 `ctype`,c3 `ctype`, PRIMARY KEY(c1)) ENGINE=`engine` `partitionby`"
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
    10) case $[$RANDOM % 7 + 1] in  # Select (needs further work)
        1) echo "`selectq`";;
        2) echo "`selectq` UNION `selectq`";;
        3) echo "`selectq` UNION `selectq` UNION `selectq`";;
        4) echo "SELECT c1 FROM `table` WHERE (c1) IN (`selectq`)";;
        5) echo "SELECT c1 FROM `table` WHERE (c1) IN (SELECT c1 FROM `table` WHERE c1 `operator` `data`)";;
        6) echo "SELECT (`selectq`)";;
        7) echo "SELECT (SELECT (`selectq`) OR (`selectq`)) AND (SELECT (SELECT (`selectq`) AND (`selectq`))) OR ((`selectq`) AND (`selectq`)) OR (`selectq`)";;
        *) echo "Assert: invalid random case selection in main select case";;
      esac;;
    11) case $[$RANDOM % 9 + 1] in  # Delete (complete, except join clauses could be extended with `joinlron` and `joinlronla` as above)
        1) echo "DELETE `lowprio` `quick` `ignore` FROM `table` `partition` `where` `orderby` `limit`";;
        2) echo "DELETE `lowprio` `quick` `ignore` `alias3` FROM `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        3) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3` USING `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        4) echo "DELETE `lowprio` `quick` `ignore` `alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        5) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        6) echo "DELETE `lowprio` `quick` `ignore` `alias3`,`alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        7) echo "DELETE `lowprio` `quick` `ignore` FROM `alias3`,`alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        8) echo "DELETE `alias3`,`alias3` FROM `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        9) echo "DELETE FROM `alias3`,`alias3` USING `table` AS a1 `join` `table` AS a2 `lastjoin` `table` AS a3 `whereal`";;
        *) echo "Assert: invalid random case selection in DELETE case";;
      esac;;
    12) echo "TRUNCATE `table`";;  # Truncate
    13) case $[$RANDOM % 3 + 1] in  # UPDATE (needs further work)
        1) echo "UPDATE `table` SET c1=`data`";;
        2) echo "UPDATE `table` SET c1=`data` `where`";;
        3) echo "UPDATE `table` SET c1=`data` `where` `orderby` `limit`";;
        *) echo "Assert: invalid random case selection in UPDATE case";;
      esac;;
    1[4-6]) case $[$RANDOM % 12 + 1] in  # Generic statements (needs further work except flush and reset)
      [1-4]) echo "UNLOCK TABLES";;  # Do not lower frequency
      [5-6]) echo "SET AUTOCOMMIT=ON";;
        7) echo "FLUSH `nowriteloc` `flush`" | sed "s|DUMMY|`table`|";;
        8) echo "`reset`";;
        9) echo "PURGE `binmaster` LOGS TO '`data`'" | sed "s|''|'|g";;  # Not ideal, should be a real binary log filename
       10) echo "PURGE `binmaster` LOGS BEFORE CURRENT_TIMESTAMP()";;  # A datetime generator would perhaps a good addition
       11) echo "SET SQL_BIG_SELECTS=1";;
       12) echo "SET MAX_JOIN_SIZE=1000000";;
        *) echo "Assert: invalid random case selection in generic statements case";;
      esac;;
    17) echo "SET `emglobses` TRANSACTION ISOLATION LEVEL `isolation`";;  # Transaction isolation level (complete)
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
       35) echo "SHOW SLAVE STATUS FOR CHANNEL '`data`'" | sed "s|''|'|g";;  # Not ideal, should be a real replication channel
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
       [1-3]) echo "SET @cmd:=\"`query`\"";;
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
           2) echo "XA BEGIN `xid`";;  # `joinresume` can be added after `xid` later (it is not supported yet, ref http://dev.mysql.com/doc/refman/5.7/en/xa-statements.html)
         esac;;
   1[1-8]) echo "XA END `xid`";;       # `suspendfm`  can be added after `xid` later (it is not supported yet, ref http://dev.mysql.com/doc/refman/5.7/en/xa-statements.html)
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
    [3-4]) echo "COMMIT `work` `chain` `release`";;  # Excludes `COMMIT...RELEASE` SQL, as this drops client connection (`release` only produces 'NO RELEASE' in a percentage of queries)
    [5-6]) echo "ROLLBACK `work` `chain` `release`";;
        7) echo "SET autocommit=`onoff01`";;
        *) echo "Assert: invalid random case selection in transactions case";;
      esac;;
    32) case $[$RANDOM % 19 + 1] in  # Lock tables (complete)
    [1-9]) echo "UNLOCK TABLES";;  # UNLOCK is present in higher ratio below also, which helps with having more queries succeed
       10) echo "LOCK TABLES `table` `asalias3` `locktype`";;
   1[1-4]) echo "LOCK TABLES `table` `asalias3` `locktype`, `table` AS a`n9` `locktype`";;
   1[5-9]) echo "LOCK TABLES `table` `asalias3` `locktype`, `table` AS a`n9` `locktype`, `table` AS a`n9` `locktype`";;  # Locking more tables leads to a higher overall number of queries that succeed
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
        *) echo "Assert: invalid random case selection in P_S case";;
      esac;;
3[6-7]) case $[$RANDOM % 7 + 1] in  # Calling & setup of functions and procedures (complete)
      [1-2]) echo "SET @`ac`=`data`";;
          3) echo "CALL `proc`(@`ac`)";;
          4) echo "CALL `proc`(@`ac`,@`ac`)";;
          5) case $[$RANDOM % 2 + 1] in
              1) echo "SELECT @`ac`";;
              2) echo "SELECT ROW_COUNT();";;
              *) echo "Assert: invalid random case selection in func,proc SELECT subcase";;
          esac;;
          6) case $[$RANDOM % 2 + 1] in
              1) echo "SELECT `func`(@`ac`)";;
              2) echo "SELECT `func`(`data`)";;
              *) echo "Assert: invalid random case selection in function-with-var subcase";;
          esac;;
          7) case $[$RANDOM % 4 + 1] in
              1) echo "SELECT `func`(@`ac`,`data`)";;
              2) echo "SELECT `func`(`data`,`data`)";;
              3) echo "SELECT `func`(`data`,@`ac`)";;
              4) echo "SELECT `func`(@`ac`,@`ac`)";;
              *) echo "Assert: invalid random case selection in function-with-var subcase";;
          esac;;
          *) echo "Assert: invalid random case selection in func,proc case";;
        esac;;
3[8-9]) case $[$RANDOM % 4 + 1] in  # Numeric functions: this should really become a callable function so that it can be used instead of `data` for example, etc.
         1) echo "SELECT `fullnrfunc`";;
         2) echo "SELECT (`fullnrfunc`) `numsimple` (`fullnrfunc`)";;
         3) echo "SELECT (`fullnrfunc`) `numsimple` (`fullnrfunc`) `numsimple` (`fullnrfunc`)";;
         4) echo "SELECT (`fullnrfunc`) `numsimple` (`fullnrfunc`) `numsimple` (`fullnrfunc`) `numsimple` (`fullnrfunc`)";;
         *) echo "Assert: invalid random case selection in numeric functions case";;
       esac;;

     # To add:
     # http://dev.mysql.com/doc/refman/5.7/en/get-diagnostics.html
     # http://dev.mysql.com/doc/refman/5.7/en/signal.html
     # cast functions

     # TIP: when adding new options, make sure to update the original case/esac to reflect the new number of options (the number behind the '%' in the case statement at the top of the list matches the number of available 'nr)' options)
     *) echo "Assert: invalid random case selection in main case";;
  esac
}

thread(){
  for i in `eval echo {1..${QUERIES_PER_THREAD}}`; do
    while [ ${MUTEX_THREAD_BUSY} -eq 1 ]; do sleep 0.0$RANDOM; done
    MUTEX_THREAD_BUSY=1; echo "`query`;" >> out.sql; MUTEX_THREAD_BUSY=0
  done
}

# ====== Main runtime
# == Setup
if [ -r out.sql ]; then rm out.sql; fi
touch out.sql; if [ ! -r out.sql ]; then echo "Assert: out.sql not present after 'touch out.sql' command!"; exit 1; fi
# == Main run
MUTEX_THREAD_BUSY=0
PIDS=
QUERIES_PER_THREAD=$[ ${QUERIES} / ${THREADS} ]
if [ ${QUERIES_PER_THREAD} -gt 0 ]; then
  for i in `eval echo {1..${THREADS}}`; do
    thread &
    PIDS="${PIDS} $!"
  done
  wait ${PIDS}
fi
# == Process the leftover queries (result of rounding (queries/threads) into an integer result)
QUERIES_PER_THREAD=$[ ${QUERIES} - ( ${THREADS} * ${QUERIES_PER_THREAD} ) ];
if [ ${QUERIES_PER_THREAD} -gt 0 ]; then thread; fi
# == Check for failures or report outcome
if grep -qi "Assert" out.sql; then
  echo "Errors found, please fix generator.sh code:"
  grep "Assert" out.sql | sort -u | sed "s|[ ]*;$||"
  rm out.sql 2>/dev/null
else
  sed -i "s|\t| |g;s|  \+| |g;s|[ ]*,|,|g;s|[ ]*;$|;|" out.sql  # Replace tabs to spaces, replace double or more spaces with single space, remove spaces when in front of a comma
  END=`date +%s`; RUNTIME=$[ ${END} - ${START} ]; MINUTES=$[ ${RUNTIME} / 60 ]; SECONDS=$[ ${RUNTIME} % 60 ]
  echo "Done! Generated ${QUERIES} quality queries in ${MINUTES}m${SECONDS}s, and saved the results in out.sql"
  echo "Please note you may want to do:  \$ sed -i \"s|RocksDB|InnoDB|;s|TokuDB|InnoDB|\" out.sql  # depending on what MySQL distribution you are using. Or, edit engines.txt and run generator.sh again"
fi
