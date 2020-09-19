#!/bin/bash

echo '--------------------------------------------- MariaDB: 10.5.6'
grep -m1 "^MariaDB: 10.5.6" *.report
#echo '--------------------------------------------- MariaDB: 10.5.3'
#grep -m1 "^MariaDB: 10.5.3" *.report

#grep -A1 -m1 'Bug confirmed present in:' *.report | more
