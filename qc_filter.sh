#!/usr/bin/env bash
# This scipt filters some trials in QC testing
# Script should be run from the main work directory for the run
DIRLIST=""

if [ ! -d filtered ]; then
  mkdir -p filtered
fi

if [ -z "$1" ]; then
  echo "This script requires storage engine as first parameter: rocksdb or tokudb!"
  exit 1
elif [ "$1" != "rocksdb" -a "$1" != "tokudb" ]; then
  echo "Unknown storage engine parameter! Please specify rocksdb or tokudb!"
  exit 1
else
  SE="$1"
fi

move(){
for dir in ${DIRLIST}
do
  if [ -d ${dir} ]; then
    mv ${dir} filtered
  fi
done
}

### Stuff that is same for both TokuDB and RocksDB
# Filter trials where diff size is 0
DIRLIST=$(find . -maxdepth 2 -size 0|grep "diff.result"|awk -F "/" '{print $2}')
move

# Other se's don't support generated columns
DIRLIST=$(grep -i "ERROR.*3106.*is not supported for generated columns" */pquery_thread-0.*.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
move

# Other se's don't support native partitioning
#DIRLIST=$(grep -i "Please use native partitioning instead." */pquery_thread-0.*.out 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
#move

# Filter where in the output storage engine name was mentioned
DIRLIST=$(grep -iE "Rocks|Toku|Inno" */pquery_thread-0.*.out 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
move

# Different maximum row sizes
DIRLIST=$(grep -i "ERROR.*1118.*Row size too large" */pquery_thread-0.*.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
move

# Different max number of columns
DIRLIST=$(grep -i "ERROR.*1117.*Too many columns" */pquery_thread-0.*.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
move

### Specifics for some SE
if [ "${SE}" == "rocksdb" ]; then
  # MyRocks and InnoDB have different maximum key sizes
  DIRLIST=$(grep -i "create.* table.* Specified key was too long" */pquery_thread-0.*.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
  move

  # https://github.com/facebook/mysql-5.6/issues/260
  #DIRLIST=$(grep -i "Internal error: Attempt to open a table that is not present in RocksDB-SE data dictionary" */pquery_thread-0.*.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
  #move

  # MyRocks doesn't support unique indexes when table doesn't have primary key
  #DIRLIST=$(grep -i "ERROR.*1105.*Unique index support is disabled when the table has no primary key" */pquery_thread-0.RocksDB.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
  #move

  # MyRocks doesn't support Gap Lock
  DIRLIST=$(grep -i "ERROR: 1105 - Using Gap Lock" */pquery_thread-0.RocksDB.sql 2>/dev/null|awk -F '/' '{print $1}'|sort -u)
  move
fi

