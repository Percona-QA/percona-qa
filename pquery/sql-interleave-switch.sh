#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script interleaves one ore more (usually more, otherwise use sql-interleave.sh if you want to have 1-line-over-1-line interleaving) SQL statements into 
# an input SQL file on every x'th line. Set the following options below: CHUNK_SIZE (x'th line), INPUT_FILE, OUTPUT_FILE, RANDOM_NUMBER_OF_OPTIONS, SQL_OPTION_x

# This is a solid core for feature testing. Here, we have a solid core sql file (like main.sql) being interleaved with feature-specific SQL, and then stress
# tested with the pquery framework (starting with pquery-run.sh)

CHUNK_SIZE=100;   # Copy x number of lines ('chunks') from the INPUT_FILE before inserting the interleave SQL.
                  # Default: 100 (== insert interleave SQL on every 100th line). Do not set lower then 1. 
                  # Weigh off the following: Low setting (ie. low nr) = (too) large resulting a file. High setting = (too) infrequent hits of the interleaved SQL
                  # Setting this even to something like 40 will take an overnight run to complete
#INPUT_FILE=./main-merged.sql
INPUT_FILE=/home/$(whoami)/newsql/main-ms-ps-md.sql
OUTPUT_FILE=./main-interleaved-switch.sql
RANDOM_NUMBER_OF_OPTIONS=9;  # If this is changed from the default (9), then the case/esac switch needs to be updated in the code also.
                             # It is easier to just use "" (a blank string) for the slots ('options') you do not want to use. This way the code stays as-is.
                             # Note that if you only set SQL_OPTION_1 and have the others blank, then this effectively means that there is a 1-in-9 insertion
                             # (approximately - it's random after all). of this SQL. If you like it to be more, set SQL_OPTION_2 to the same etc.
                             # Also, if you use blank slots/options ("") then note these will not show as blank strings in the OUTPUT_FILE (they are filtered)	
                             # Note that if you put multiple statements on one line with '\n', then
RANDOM=`date +%s%N | cut -b14-19`  # Random entropy pool init, do not change
# SQL_OPTION Syntax: 
# * Use ";" as a EOL/terminating character. You also need to use '\n' if you want to list 2 statements per option. Do not put '\n' at the end of a string/line.
# * Note that if you put multiple statements on one line with '\n', then it does not mean these statements are executed sequentially. They are rather listed
#   in the file sequentially, and as pquery uses a single line randomly from this file, either statement may be executed independently at any time.
#   There is currently no workaround/way to execute multiple statements in sequence, but feel free to code it/add it. 
# * Use $(( RANDOM % 1000 + 1 )) for a random number, where the number needs to be between 1 and X (X being 1000 in this example)
# 3 Examples:
# SQL_OPTION_1="DROP TABLE t1;\nCREATE TABLE t1 (c1 INT PRIMARY KEY);"
# SQL_OPTION_2="SET @@GLOBAL.TOKUDB_FANOUT=$(( RANDOM % 16385 + 1 ));"  # 1-16385
# SQL_OPTION_3="SELECT 1;"
SQL_OPTION_1="SET @@GLOBAL.expand_fast_index_creation=ON;"
SQL_OPTION_2="SET @@GLOBAL.expand_fast_index_creation=OFF;"
SQL_OPTION_3="SET @@SESSION.expand_fast_index_creation=ON;"
SQL_OPTION_4="SET @@SESSION.expand_fast_index_creation=OFF;"
SQL_OPTION_5="SET @@GLOBAL.expand_fast_index_creation=ON;"
SQL_OPTION_6="SET @@GLOBAL.expand_fast_index_creation=OFF;"
SQL_OPTION_7="SET @@SESSION.expand_fast_index_creation=ON;"
SQL_OPTION_8="SET @@SESSION.expand_fast_index_creation=OFF;"
SQL_OPTION_9="SET @@GLOBAL.expand_fast_index_creation=ON;"

if [ ! -r ${INPUT_FILE} ]; then
  echo "Assert: ${INPUT_FILE} was not found. Please check. Terminating."
  exit 1
fi
if [ ${CHUNK_SIZE} -lt 1 ]; then
  echo "Assert: CHUNK_SIZE is set to ${CHUNK_SIZE} which is less then the required minimum 1. Terminating."
  exit 1
fi

rm -f ${OUTPUT_FILE}
touch ${OUTPUT_FILE}
if [ ! -r ${OUTPUT_FILE} ]; then
  echo "Assert: we tried creating ${OUTPUT_FILE}, but did not succeed. Please check privileges etc. Terminating."
  exit 1
fi

COUNT=1  # Always 1 to start, do not modify
while [ ${COUNT} -lt `wc -l <${INPUT_FILE}` ]; do
  # Insert chunk from input file (1 or more lines)
  # head -nx | tail -ny version takes about 11 minutes on high-end machine for main.sql. awk version is much slower at 27+ minutes. Still to try; sed
  # awk "NR>=${COUNT}&&NR<=$[ ${COUNT} + ${CHUNK_SIZE} - 1 ]" ${INPUT_FILE} >> ${OUTPUT_FILE}
  head -n$[ ${COUNT} + ${CHUNK_SIZE} - 1 ] ${INPUT_FILE} | tail -n${CHUNK_SIZE} | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE}
  # Insert random SQL_OPTION
  RANDOM=$(date +%s%N | cut -b14-19)
  case $[$RANDOM % ${RANDOM_NUMBER_OF_OPTIONS} + 1] in
    1) echo -e "${SQL_OPTION_1}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    2) echo -e "${SQL_OPTION_2}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    3) echo -e "${SQL_OPTION_3}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    4) echo -e "${SQL_OPTION_4}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    5) echo -e "${SQL_OPTION_5}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    6) echo -e "${SQL_OPTION_6}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    7) echo -e "${SQL_OPTION_7}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    8) echo -e "${SQL_OPTION_8}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    9) echo -e "${SQL_OPTION_9}" | grep -E --binary-files=text -v "^[ \t]*$" >> ${OUTPUT_FILE} ;;
    *) echo 'Assert: Something went wrong. Did you set RANDOM_NUMBER_OF_OPTIONS to correct number of random options etc.?'; exit 1 ;;
  esac
  COUNT=$[ ${COUNT} + ${CHUNK_SIZE} ]
done

