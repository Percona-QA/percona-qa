#!/bin/bash
# Created by Ramesh Sivaraman & Roel Van de Paar, Percona LLC
# This script processed dynamic variables only

SCRIPT_PWD=$(cd `dirname $0` && pwd)
VERSION_CHECK=$1; 
if [ "`echo $VERSION_CHECK | grep -oe '5\.[67]'`" != "5.6" ] && [ "`echo $VERSION_CHECK | grep -oe '5\.[67]'`" != "5.7" ];then
  VERSION_CHECK="5.7"
fi

#rm -Rf /tmp/get_all_options
#mkdir /tmp/get_all_options
#if [ ! -d /tmp/get_all_options ]; then echo "Assert: /tmp/get_all_options does not exist after creation!"; exit 1; fi
cd /tmp/get_all_options

#wget http://dev.mysql.com/doc/refman/$VERSION_CHECK/en/server-system-variables.html
grep '<colgroup><col class="name">' server-system-variables.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | grep -E "Both|Session" | grep 'Yes[ \t]*$' | awk '{print $1}' | sed 's|_|-|g' > session.txt
grep '<colgroup><col class="name">' server-system-variables.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | grep -E "Both|Global" | grep 'Yes[ \t]*$' | awk '{print $1}' | sed 's|_|-|g' > global.txt
grep -o "Command-Line Format.*\-\-[^<]\+" server-system-variables.html | grep -o "\-\-.*" | sed 's|_|-|g' > commandlines.txt

#wget http://dev.mysql.com/doc/refman/$VERSION_CHECK/en/innodb-parameters.html
grep '<colgroup><col class="name">' innodb-parameters.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | grep -E "Both|Session" | grep 'Yes[ \t]*$' | awk '{print $1}' | sed 's|_|-|g' >> session.txt
grep '<colgroup><col class="name">' innodb-parameters.html | sed 's|<tr>|\n|g;s|<[^>]*>| |g;s|-   Variable  :||g' | grep -vE "^[ \t]*$|Name  Cmd-Line|Reference" | grep -E "Both|Global" | grep 'Yes[ \t]*$' | awk '{print $1}' | sed 's|_|-|g' >> global.txt
grep -o "Command-Line Format.*\-\-[^<]\+" innodb-parameters.html | grep -o "\-\-.*" | sed 's|_|-|g' >> commandlines.txt

# varlist syntax:   Name (1) Cmd-Line (2)  Option File (3)  System Var (4)  Var Scope (5)  Dynamic (6)  (can use awk '{print $x}')
VERSION_CHECK=`echo $VERSION_CHECK | sed 's|\.||g'`  # Only change this after retrieving the pages above

parse_set_vars(){
  rm ${VARFILE}.out
  while read line; do
    if grep -q $line ./commandlines.txt; then
      PRLINE=$(grep $line ./commandlines.txt)
      echo ${PRLINE} | if grep -q '={OFF|ON}'; then 
        PRLINE=$(echo ${PRLINE} | sed 's/={OFF|ON}//')
        echo "${PRLINE}=0" >> ${VARFILE}.out
        echo "${PRLINE}=1" >> ${VARFILE}.out
      fi
      echo ${PRLINE} | if grep -q '=[{OFF|ON}]'; then 
        PRLINE=$(echo ${PRLINE} | sed 's/=\[{OFF|ON}\]//')
        echo "${PRLINE}" >> ${VARFILE}.out  # Without anything (as [x] means x is optional)
        echo "${PRLINE}=0" >> ${VARFILE}.out
        echo "${PRLINE}=1" >> ${VARFILE}.out
      fi
      echo ${PRLINE} | if grep -q '=#'; then
        echo "${PRLINE}" | sed 's|=#|=DUMMY|' >> ${VARFILE}.out
      fi
      echo ${PRLINE} | if grep -q '=[#]'; then
        echo "${PRLINE}" | sed 's|=[#]|=DUMMY|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=[#]||' >> ${VARFILE}.out  # Without anything, ref above
      fi
    else
      echo $line >> as_yet_to_handle.txt
    fi
  done < ${VARFILE}
}

VARFILE=session.txt; parse_set_vars
VARFILE=global.txt;  parse_set_vars

#  if [ $(grep -c $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt ) -ne 0 ];then
#    if [ $(grep -c $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt ) -eq 2 ];then
#      grep $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt | sed 's|--||g;s|-|_|g' >> setvar_$VERSION_CHECK.txt
#    else
#      TEST_VAL=`grep $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt | cut -d"=" -f2 | head -n1`
#      if [ "$TEST_VAL" -eq "$TEST_VAL" ] 2>/dev/null; then
#        echo "$line=DUMMY" | sed 's|-|_|g' >> setvar_$VERSION_CHECK.txt
#      else
#        grep $line $SCRIPT_PWD/pquery/mysqld_options_ms_${VERSION_CHECK}.txt | sed 's|--||g;s|-|_|g'  >> setvar_$VERSION_CHECK.txt
#      fi
#    fi
#  else
#    echo $line >> missing_setvar_$VERSION_CHECK.txt
#  fi
#done < varlist.txt
#echo "Done! Results are in; /tmp/get_all_options/setvar_$VERSION_CHECK.txt"

