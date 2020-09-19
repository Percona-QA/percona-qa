#!/bin/bash
set +H

STARTFLAG=0  # 1 When 'directly_executable_statement:' was seen (start from here), 0 at start
STARTC=0     # 0 When not reading inside a C-code block, set to location of first '{' otherwise
STARTCOM=0   # 0 When not reading inside a comment block
while IFS=$'\n' read LINE; do
  # Changing /*empty*/ and /*nothing*/ to token, and remove /*...*/ and {...}
  LINE="$(echo "${LINE}" | sed "s|/\*[ ]*empty[ ]*\*/|EMPTY|ig;s|/\*[ ]*nothing[ ]*\*/|EMPTY|ig;s|/\*.*\*/||;s|{.*}||")"  
  CHECK_COMMENT_L="$(echo "${LINE}" | sed 's|^[ \t]\+||' | grep -o '^..')"  # LHS
  if [ "${CHECK_COMMENT_L}" == "//" -o "${CHECK_COMMENT_L}" == "**" ]; then continue; fi
  if [ ${STARTC} -gt 0 ]; then  # Currently reading a C-code block
    if [[ "${LINE}" == *"}"* ]]; then 
      if [ "$(echo "${LINE}" | sed 's|}.*|_|' | tr -d '\n' | wc -c)" == ${STARTC} ]; then
        STARTC=0  # Last line of most outlined C-code block (as tested by STARTC indent matching)
      fi
    fi
    continue  # Continue inside, and at the end of, C-code blocks
  fi
  if [ "${CHECK_COMMENT_L}" == "/*" ]; then STARTCOM=1; continue; fi
  if [ ${STARTCOM} -eq 1 ]; then
    CHECK_COMMENT_R="$(echo "${LINE}" | sed 's|[ \t]\+$||' | grep -o '..$')"  # RHS
    if [ "${CHECK_COMMENT_R}" == "*/" ]; then
      STARTCOM=0
    fi
    continue  # Continue inside, and at the end of, comment blocks
  fi
  if [ ${STARTFLAG} -eq 0 ]; then 
    if [ "${LINE}" == "directly_executable_statement:" ]; then STARTFLAG=1; else continue; fi  # Start at query: only
  fi
  if [[ "${LINE}" == *"{"* && "${LINE}" == *"}"* ]]; then 
    LINE="$(echo "${LINE}" | sed 's|{.*}||g')"  # Remove "{...}" from any line
  fi
  if [[ "${LINE}" == *"{"* ]]; then  # First line of C-code block
    STARTC="$(echo "${LINE}" | sed 's|{.*|_|' | tr -d '\n' | wc -c)"  # First '{' location
    if [ ${STARTC} -le 0 ]; then echo "Assert: STARTC -le 0: ${STARTC} -le 0"; exit 1; fi
    continue
  fi
  REDUCED_LINE="$(echo "${LINE}" | sed 's|[ \t]||g')"
  if [ "${REDUCED_LINE}" == "" ]; then continue; fi  # Skip empty lines
  if [ "${REDUCED_LINE}" == ";" ]; then continue; fi  # End of key/valuepairs, skip line with ;
  if [ "${REDUCED_LINE}" == "|" ]; then continue; fi  # Skip line with |
  LINE="$(echo "${LINE}" | sed "s|\t|  |;s|'@'|SYMB_LEFT_AT|g;s|'('|SYMB_LEFT_PAR|g;s|')'|SYMB_RIGHT_PAR|g;s|'\.'|SYMB_DOT|g;s|','|SYMB_COMMA|g;s|'='|SYMB_EQUALS|g;s|^[ ]\+| |;s/^ | / /;s|  | |g;s| $||g")"
  if [[ "${LINE}" == *":"* ]]; then 
    if [[ "${LINE}" != *":" ]]; then  # Line was not constructed correclty in original grammar
      LINE1="$(echo "${LINE}" | sed 's|:.*|:|')"
      LINE2="$(echo "${LINE}" | sed 's|.*:[ ]*| |')"
      echo "${LINE1}"  # Key
      echo "${LINE2}"  # Value
      # The file was also scanned for ':.*:' and this was not present; no further check required
    else
      echo "${LINE}"  # Key
    fi
  else
    echo "${LINE}"  # Value
  fi
done < sql/sql_yacc.yy
