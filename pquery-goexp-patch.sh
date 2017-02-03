#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# This script quickly patches a reducer<trialnr>.sh script from FORCE_SKIPV on to off, and sets it to the already reduced _out sql file.
# This is very handy when the following procedure was used;
# pquery-run.sh > pquery-go-expert.sh > {reducer<trialnr>.sh or pquery-mass-reducer.sh} > testcase reduced but now stuck at stage1 and ~4 lines (multi-threaded) > this script >
# restart reducer<trialnr>.sh with the said changes done by this script. It will then run through all other stages

sed -i "s|^FORCE_SKIPV=1|FORCE_SKIPV=0|" reducer$1.sh
sed -i "s|default.node.tld_thread-0.sql\"$|default.node.tld_thread-0.sql_out\"|" reducer$1.sh
