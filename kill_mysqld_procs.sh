#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Terminates all owned live mysql and mysqld processes
ps -ef | egrep "mysql" | grep "$(whoami)" | egrep -v "grep" | awk '{print $2}' | xargs kill -9 2>/dev/null
