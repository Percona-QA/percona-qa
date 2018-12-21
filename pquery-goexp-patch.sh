#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script quickly patches a reducer<trialnr>.sh script from FORCE_SKIPV on to off, and sets it to the already reduced _out sql file.
# This is very handy when the following procedure was used;
# pquery-run.sh > pquery-go-expert.sh > {reducer<trialnr>.sh or pquery-mass-reducer.sh} > testcase reduced but now stuck at stage1 and ~4 lines (multi-threaded) > this script >
# restart reducer<trialnr>.sh with the said changes done by this script. It will then run through all other stages

if [ "$1" == "" ]; then
  echo "Assert: This script expects one option, namely the trial number for which this script should patch reducer<trialnr>.sh"
  echo "Terminating."
  exit 1
elif [ "$(echo $1 | sed 's|^[0-9]\+||')" != "" ]; then
  echo "Assert: option passed is not numeric. If you do not know how to use this script, execute it without options to see more information"
  exit 1
fi

sed -i "s|^FORCE_SKIPV=1|FORCE_SKIPV=0|" reducer$1.sh
sed -i "s|^STAGE1_LINES=[0-9]\+|STAGE1_LINES=1000|" reducer$1.sh
# TODO The following line can be improved further to check what the latest _out_out_out etc. is and to use that one. There is a small risk however that the last _out is not the desired one. That seems minor
sed -i "s|default.node.tld_thread-0.sql\"$|default.node.tld_thread-0.sql_out\"|" reducer$1.sh
