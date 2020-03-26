#!/bin/bash
# Created by Roel Van de Paar, MariaDB

SCRIPT_PWD=$(cd `dirname $0` && pwd)
${SCRIPT_PWD}/new_text_string.sh "$1" | head -n5 | tail -n3 | sed 's| [^ ]\+$||' | tr '\n' '|' | sed 's/|$/\n/'
