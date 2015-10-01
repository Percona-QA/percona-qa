#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Quickly opens up a mysql session to an active (pquery-run.sh iniated) mysqld session
# As pquery-run.sh is single-threaded and consecutive, there is always only one mysqld sessions alive

`ps -ef | grep mysqld | grep -v grep | grep "dev/shm" | sed 's|mysqld .*|mysql|;s|.* \(.*mysql\)|\1|'` -uroot -S`ps -ef | grep mysqld | grep -v grep | grep "dev/shm" | sed 's|.*socket=||;s| .*||'`
