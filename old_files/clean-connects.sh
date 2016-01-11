#!/bin/bash

# Get the trial directories from run directory
PQUERY_DIR=`ls -d [0-9]*`

# Clean connect queries from pquery sql file.
for i in ${PQUERY_DIR[*]}; do
  echo "=== Processing trial $i"
  if [ -r $i/pquery_thread-0.sql.old ]; then  # Second round (swap back to old original) + safety copy (to new)
    rm $i/pquery_thread-0.sql.new 2>/dev/null
    mv $i/pquery_thread-0.sql $i/pquery_thread-0.sql.new
    mv $i/pquery_thread-0.sql.old $i/pquery_thread-0.sql
  fi
  mv $i/pquery_thread-0.sql  $i/pquery_thread-0.sql.old
  if [ ! -f $i/pquery_thread-0.sql ]; then
    grep -vi "^[ \t]*connect" $i/pquery_thread-0.sql.old | \
    grep -vi "^[ \t]*disconnect" | \
    grep -vi "\\\q" | \
    grep -vi "\\\u" | \
    grep -vi "\\\r" | \
    grep -vi "^#" | \
    grep -vi "FLUSH LOCAL TABLES;" > $i/pquery_thread-0.sql
  else
    echo "Something wrong... Did not move pquery_thread-0.sql file from $i"
  fi  
done

