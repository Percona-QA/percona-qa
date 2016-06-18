#!/bin/bash
# Created by Ramesh Sivaraman & Roel Van de Paar, Percona LLC

rm -Rf /tmp/get_all_options
mkdir /tmp/get_all_options
if [ ! -d /tmp/get_all_options ]; then echo "Assert: /tmp/get_all_options does not exist after creation!"; exit 1; fi
cd /tmp/get_all_options

wget http://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html
wget http://dev.mysql.com/doc/refman/5.7/en/innodb-parameters.html

grep '<colgroup><col class="name">' server-system-variables.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g' | grep -v 'Variable  :' > varlist1.txt
grep '<colgroup><col class="name">' innodb-parameters.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g' | grep -v 'Variable  :' > varlist2.txt

