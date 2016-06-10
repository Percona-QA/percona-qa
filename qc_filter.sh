#!/bin/bash
# This scipt filters some trials in QC testing (currently for FB)
# Script should be run from the main work directory for the run
DIRLIST=""

if [ ! -d filtered ]; then
  mkdir -p filtered
fi

move(){
for dir in ${DIRLIST}
do
  mv ${dir} filtered
done
}

# MyRocks and InnoDB have different maximum key sizes
DIRLIST=$(grep -i "create table.* Specified key was too long" */pquery_thread-0.*.sql|awk -F '/' '{print $1}'|uniq)
move

# https://github.com/facebook/mysql-5.6/issues/260
DIRLIST=$(grep -i "Internal error: Attempt to open a table that is not present in RocksDB-SE data dictionary" */pquery_thread-0.*.sql|awk -F '/' '{print $1}'|uniq)
move

# MyRocks and InnoDB have different maximum row sizes
DIRLIST=$(grep -i "ERROR 1118 (42000): Row size too large" */pquery_thread-0.*.sql|awk -F '/' '{print $1}'|uniq)
move

# filter trials where diff size is 0
DIRLIST=$(find . -maxdepth 2 -size 0|grep "diff.result"|awk -F "/" '{print $2}')
move

