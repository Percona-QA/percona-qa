#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# Terminates all owned QA-relevant processes
ps -ef | egrep "mysql"     | grep "$(whoami)" | egrep -v "grep|vim" | awk '{print $2}' | xargs kill -9 2>/dev/null
ps -ef | egrep "reducer"   | grep "$(whoami)" | egrep -v "grep|vim" | awk '{print $2}' | xargs kill -9 2>/dev/null
ps -ef | egrep "valgrind"  | grep "$(whoami)" | egrep -v "grep|vim" | awk '{print $2}' | xargs kill -9 2>/dev/null
ps -ef | egrep "pquery"    | grep "$(whoami)" | egrep -v "grep|vim" | awk '{print $2}' | xargs kill -9 2>/dev/null
ps -ef | egrep "go-expert" | grep "$(whoami)" | egrep 0v "grep|vim" | awk '{print $2}' | xargs kill -9 2>/dev/null
