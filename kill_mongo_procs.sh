#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Terminates all live mongo, mongod, mongos processes, avoiding script termination
ps -ef | egrep "mongo" | grep "$(whoami)" | egrep -v "grep|vim|_mongo|regression" | awk '{print $2}' | xargs kill -9 2>/dev/null
