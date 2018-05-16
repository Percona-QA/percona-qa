#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Terminates all live mongo, mongod, mongos processes, avoiding script termination &
# ensures (grep "$$") that only processes started in this shell are terminated
ps -ef | egrep "mongo" | grep "$(whoami)" | egrep -v "grep|vim|_mongo|regression" | grep "$$" | awk '{print $2}' | xargs kill -9 2>/dev/null
