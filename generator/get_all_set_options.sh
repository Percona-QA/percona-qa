#!/bin/bash
# Created by Ramesh Sivaraman & Roel Van de Paar, Percona LLC
# This script processes dynamic variables (global + session) and writes generator.sh compatible files for them into /tmp/get_all_options

SCRIPT_PWD=$(cd `dirname $0` && pwd)
if [ "$1" == "" ]; then
  VERSION_CHECK="5.7"
elif [ "`echo $1 | grep -oe '5\.[67]'`" != "5.6" ] && [ "`echo $1 | grep -oe '5\.[67]'`" != "5.7" ];then
  echo "Invalid option. Valid options are: 5.6 and 5.7, e.g. ./get_all_set_options.sh 5.7"
  echo "If no option is given, 5.7 will be used by default"
  exit 1
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
sed -i "s/=\[={OFF|ON}\]/[={OFF|ON}]/" commandlines.txt

rm as_yet_to_handle.txt todo.txt 2>/dev/null
parse_set_vars(){
  rm ${VARFILE}.out 2>/dev/null
  while read line; do
    if grep -q $line ./commandlines.txt; then  # ================= STAGE 0: Line is present in "Command-Line Format" capture file; use this to handle setting variables
      PRLINE=$(grep $line ./commandlines.txt); HANDLED=0
      if ! [[ "${PRLINE}" == *"="* ]]; then  # Variable without any options, for example --general-log
        echo "${PRLINE}" >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"[={OFF|ON}]"* ]]; then
        PRLINE=$(echo ${PRLINE} | sed 's/\[={OFF|ON}\]//')
        echo "${PRLINE}" >> ${VARFILE}.out  # Without anything (as [x] means x is optional)
        echo "${PRLINE}=0" >> ${VARFILE}.out
        echo "${PRLINE}=1" >> ${VARFILE}.out
        HANDLED=1
      fi
      if [ ${HANDLED} -eq 0 ]; then
        if [[ "${PRLINE}" == *"={OFF|ON}"* ]]; then
          PRLINE=$(echo ${PRLINE} | sed 's/={OFF|ON}//')
          echo "${PRLINE}=0" >> ${VARFILE}.out
          echo "${PRLINE}=1" >> ${VARFILE}.out
          HANDLED=1
        fi
      fi
      if [[ "${PRLINE}" == *"[=#]"* ]]; then
        echo "${PRLINE}" | sed 's|\[=#\]|=DUMMY|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|\[=#\]||' >> ${VARFILE}.out  # Without anything, ref above
        HANDLED=1
      fi
      if [ ${HANDLED} -eq 0 ]; then
        if [[ "${PRLINE}" == *"=#"* ]]; then
          echo "${PRLINE}" | sed 's|=#|=DUMMY|' >> ${VARFILE}.out
          HANDLED=1
        fi
      fi
      if [[ "${PRLINE}" == *"=engine[,engine]..."* ]]; then
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=MyISAM|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=InnoDB|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=CSV|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=MRG_MYISAM|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=TokuDB|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=RocksDB|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=BLACKHOLE|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=PERFORMANCE_SCHEMA|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=MEMORY|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=FEDERATED|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=CSV,FEDERATED|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=engine\[,engine\]...|=CSV,MRG_MYISAM|' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"default-authentication-plugin=plugin-name"* ]]; then
        echo "${PRLINE}" | sed 's|=plugin-name|=mysql_native_password|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=plugin-name|=sha256_password|' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"=dir-name"* ]] || [[ "${PRLINE}" == *"=path"* ]] || [[ "${PRLINE}" == *"=directory"* ]]; then
        # These variables (--datadir, --character-sets-dir, --basedir etc.) are skipped as they do not make sense to modify, and they are unlikely to be dynamic;
        # Note that this ifthen may not even be hit for all cases present in commandlines.txt. For example, --datadir is not dynamic and so it will not be in global/session txt
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"event-scheduler[=value]"* ]]; then
        echo "${PRLINE}" | sed 's|=[value]|=ON|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=[value]|=OFF|' >> ${VARFILE}.out
        echo "${PRLINE}" | sed 's|=[value]|=DISABLED|' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [[ "${PRLINE}" == *"7"* ]]; then
        echo "${PRLINE}" | sed 's|=||' >> ${VARFILE}.out
        HANDLED=1
      fi
      if [ ${HANDLED} -eq 0 ]; then
        echo $PRLINE >> todo.txt
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

