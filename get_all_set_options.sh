#!/bin/bash
# Created by Ramesh Sivaraman & Roel Van de Paar, Percona LLC

SCRIPT_PWD=$(cd `dirname $0` && pwd)
VERSION_CHECK=$1
if [ "`echo $VERSION_CHECK | grep -oe '5\.[67]'`" != "5.6" ] && [ "`echo $VERSION_CHECK | grep -oe '5\.[67]'`" != "5.7" ];then
  VERSION_CHECK="5.7"
fi

IS_DYNAMIC=1

rm -Rf /tmp/get_all_options
mkdir /tmp/get_all_options
if [ ! -d /tmp/get_all_options ]; then echo "Assert: /tmp/get_all_options does not exist after creation!"; exit 1; fi
cd /tmp/get_all_options
TEMP_DIR="/tmp/get_all_options"

wget http://dev.mysql.com/doc/refman/$VERSION_CHECK/en/server-system-variables.html
wget http://dev.mysql.com/doc/refman/$VERSION_CHECK/en/innodb-parameters.html

VERSION_CHECK=`echo $VERSION_CHECK | sed 's|\.||g'`

if [ $IS_DYNAMIC -eq 1 ];then
  grep '<colgroup><col class="name">' server-system-variables.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | grep 'Yes  $' | awk '{print $1}' | sed 's|_|-|g' | sort | uniq > varlist1.txt
  grep '<colgroup><col class="name">' innodb-parameters.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | grep 'Yes  $' | awk '{print $1}' | sed 's|_|-|g' | sort | uniq > varlist2.txt
else
  grep '<colgroup><col class="name">' server-system-variables.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | awk '{print $1}' | sed 's|_|-|g' | sort | uniq > varlist1.txt
  grep '<colgroup><col class="name">' innodb-parameters.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | awk '{print $1}' | sed 's|_|-|g' | sort | uniq > varlist2.txt
fi

# varlist syntax:   Name (1) Cmd-Line (2)  Option File (3)  System Var (4)  Var Scope (5)  Dynamic (6)  (can use awk '{print $x}')

#Merge variable set
cat $TEMP_DIR/varlist1.txt $TEMP_DIR/varlist2.txt | sort | uniq > $TEMP_DIR/varlist.txt

while read line; do
  if [ $(grep -c $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt ) -ne 0 ];then
    if [ $(grep -c $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt ) -eq 2 ];then
      grep $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt | sed 's|--||g;s|-|_|g' >> $TEMP_DIR/setvar_$VERSION_CHECK.txt
    else
      TEST_VAL=`grep $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt | cut -d"=" -f2 | head -n1`
      if [ "$TEST_VAL" -eq "$TEST_VAL" ] 2>/dev/null; then
        echo "$line=DUMMY" | sed 's|-|_|g' >> $TEMP_DIR/setvar_$VERSION_CHECK.txt
      else
        grep $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt | sed 's|--||g;s|-|_|g'  >> $TEMP_DIR/setvar_$VERSION_CHECK.txt
      fi
    fi
  else
    echo $line >> $TEMP_DIR/missing_setvar_$VERSION_CHECK.txt
  fi
done < $TEMP_DIR/varlist.txt


