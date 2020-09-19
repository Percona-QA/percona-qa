#!/bin/bash

# User vars
DO_SETUP=0            # Do a full run, including re-creating the xml using the yacc input grammar
DO_XML2TXT=0          # Do a XML to TXT conversion (required if no sql_yacc_level1.txt is present)
BASEDIR="/test/10.5"  # MariaDB/MySQL/Percona server base directory
MAX_LEVEL=1           # Maxium creation scan depth
START_KEY='query'     # Start key, for example 'query' (default), 'alter' etc. see input for more
QUERY_MAX=10           # Max number of queries to generate

# Variables check and setup
if [ -z "${MAX_LEVEL}" ]; then echo "Assert: MAX_LEVEL is not set."; exit 1; fi
if [ -z "${START_KEY}" ]; then echo "Assert: START_KEY is not set."; exit 1; fi
if [ "${DO_SETUP}" -eq 1 ]; then
  if [ -z "$(whereis -b bison | sed 's|bison:[ \t]||')" ]; then echo "Assert bison not found. Use: sudo apt install bison"; exit 1; fi
  if [ -z "$(whereis -b xml2 | sed 's|xml2:[ \t]||')" ]; then echo "Assert xml2 not found. Use: sudo apt install xml2"; exit 1; fi
  DO_XML2TXT=1
  if [ ! -r ${BASEDIR}/sql/sql_yacc.yy ]; then echo "Assert: ${BASEDIR}/sql/sql_yacc.yy not present or not readable by this script!"; exit 1; fi
  cp ${BASEDIR}/sql/sql_yacc.yy ./sql/
  if [ ! -r ./sql/sql_yacc.yy ]; then echo "Assert: ./sql/sql_yacc.yy not present after copy attempt!"; exit 1; fi
  rm -f sql_yacc.xml sql_yacc.txt sql_yacc.tab.cc
  bison -x ./sql/sql_yacc.yy && rm sql_yacc.tab.cc
  if [ ! -r ./sql_yacc.xml ]; then echo "Assert: ./sql_yacc.xml not found after executing bison -x ./sql/sql_yacc.yy"; exit 1; fi
  xml2 < sql_yacc.xml > sql_yacc.txt
  rm -f sql_yacc.xml
fi

# XML-2-TXT
if [ "${DO_XML2TXT}" -eq 1 ]; then
  grep --binary-files=text -E '/bison-xml-report/grammar/rules' sql_yacc.txt | \
   grep --binary-files=text -vE '/rules/rule$|=useful$|rhs/symbol$' | \
   sed 's|/bison-xml-report/grammar/rules/rule/||;s|^@number=\([0-9]\+\)[ \t]*$|\1|;s|^lhs=|l=|;s|^rhs/symbol=|r=|;s|rhs/empty|r=empty|' > sql_yacc_level1.txt
  rm -f sql_yacc.txt
fi

subread(){
  SUBREAD_QUERY=''
echo "${1}--"
  local LHS_QUERY="l=${1}" 
  local SEARCHING=1  # 1: Indicates search mode is active
  local READ_RHS=0   # 1: Indicates we're reading r= RHS entries
  local QUERY_CNT=0  # Generated queries counter
  local LINE=''
  while IFS=$'\n' read LINE; do  # Sub reading loop; for any depth
    local LHS=0;local RHS=0;local SPECIAL=0;
    if   [[ ${LINE} =~ ^[0-9]+$ ]]; then 
      if [ "${SEARCHING}" -eq 0 ]; then break; fi  # Finished
      READ_RHS=0;  # Can be removed?
    elif [[ ${LINE} =~ ^l= ]]; then LHS=1;
    elif [[ ${LINE} =~ ^r= ]]; then RHS=1;
    elif [[ ${LINE} =~ ^@percent ]]; then SPECIAL=1;
    else "Assert: invalid read: ${LINE}"; exit 1; 
    fi
    if [ ${SEARCHING} -eq 1 -a ${LHS} -eq 1 ]; then  # Searching + new LHS found
      if [[ ${LINE} == ${LHS_QUERY} ]]; then  # Search string match found
        READ_RHS=1  # Start RHS reads (until a new number-only line is found)
        SEARCHING=0
    fi;fi
    if [ ${READ_RHS} -eq 1 -a ${RHS} -eq 1 ]; then
      local RHS_TEXT="$(echo "${LINE}" | sed 's|^r=||')"
      # There is no LHS's like these: 'l=END_OF_INPUT' nor 'l=empty', i.e. they are end points
      if [[ ${RHS_TEXT} == END_OF_INPUT ]]; then break  # End of query
      elif [[ ${RHS_TEXT} == empty ]]; then SUBREAD_QUERY="${SUBREAD_QUERY} "  # Just empty
      else SUBREAD_QUERY="${SUBREAD_QUERY} ${RHS_TEXT}"
      fi
    fi
  done < sql_yacc_level1.txt
}

LHS_QUERY="l=${START_KEY}"
SEARCHING=1  # 1: Indicates search mode is active
READ_RHS=0   # 1: Indicates we're reading r= RHS entries
QUERY_CNT=0  # Generated queries counter
while true; do
  QUERY=''
  STACK=()
  END_QUERY=0  # Flag to indicate query generation was finished
  while IFS=$'\n' read LINE; do  # Main file reading loop
    LHS=0;RHS=0;SPECIAL=0;
    if   [[ ${LINE} =~ ^[0-9]+$ ]]; then READ_RHS=0;
    elif [[ ${LINE} =~ ^l= ]]; then LHS=1;
    elif [[ ${LINE} =~ ^r= ]]; then RHS=1;
    elif [[ ${LINE} =~ ^@percent ]]; then SPECIAL=1;
    else "Assert: invalid read: ${LINE}"; exit 1; 
    fi
    if [ ${SEARCHING} -eq 1 -a ${LHS} -eq 1 ]; then  # Searching + new LHS found
      if [[ ${LINE} == ${LHS_QUERY} ]]; then  # Search string match found
        READ_RHS=1  # Start RHS reads (until a new number-only line is found)
    fi;fi
    if [ ${READ_RHS} -eq 1 -a ${RHS} -eq 1 ]; then
      RHS_TEXT="$(echo "${LINE}" | sed 's|^r=||;s| ||g')"
      # There is no LHS's like these: 'l=END_OF_INPUT' nor 'l=empty', i.e. they are end points

      # This is an endpoint for a subloop only!
      if   [[ ${RHS_TEXT} == END_OF_INPUT ]]; then  # End of query
        if [ ! -z "${QUERY}" ]; then echo "${QUERY}" | sed "s|';'.*|;|"; fi
        QUERY=''
      elif [[ ${RHS_TEXT} == empty ]]; then QUERY="${QUERY}_";  # Just empty
      else
        if [[ ${RHS_TEXT} =~ ^[_0-9a-z]+$ ]]; then  # Lowercase: further recusion needed
          subread "${RHS_TEXT}"
        else
          QUERY="${QUERY} ${RHS_TEXT}"
        fi
      fi
    fi
  done < sql_yacc_level1.txt
  if [ "${END_QUERY}" -eq 1 ]; then 
    QUERY_CNT=$[ ${QUERY_CNT} + 1 ]
    if [ ${QUERY_CNT} -ge ${QUERY_MAX} ]; then break; fi
  fi
done
















# /automaton/state$|state/solved-conflicts$|state/actions/errors$|state/actions/transitions$|itemset/item$|actions/reductions$|transitions/transition$
