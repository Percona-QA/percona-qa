#!/bin/bash

echo '--------------------------------------------- MariaDB: 10.5.4'
grep -m1 "^MariaDB: 10.5.4" *.report
echo '--------------------------------------------- MariaDB: 10.5.3'
grep -m1 "^MariaDB: 10.5.3" *.report

#grep -A1 -m1 'Bug confirmed present in:' *.report | more
