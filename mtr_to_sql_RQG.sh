#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

# THE USE OF THIS FILE IS DEPRECATED IN FAVOR OF mtr_to_sql.sh, WHICH NOW ONLY GENERATES SQL GRAMMARS FOR PQUERY. WE NO LONGER USE RQG, BUT THIS SCRIPT IS HERE FOR ANYONE WHO
# WHO WOULD LIKE TO CONTINUE GENERATING RQG COMPATIBLE GRAMMARS. THIS SCRIPT NO LONGER GENERATES PQUERY COMPATIBLE GRAMMARS (FOR THAT USE mtr_to_sql.sh INSTEAD), AND IT HAS
# MANY LIMITIONS THAT THE NEW SCRIPT DOES NOT HAVE: 1) IT STILL USES TWO INDERDEPENDENT APPROACHES (REF VERSION 1/2 BELOW), WHICH HAVE TO BE SELECTED MANUALLY, 2) IT DOES NOT
# VARY THE RESULTING SQL GRAMMARS (THE NEW SCRIPT FOR EXAMPLE VARIES THE RESULTING SQL TO INCLUDE MORE SEARCH ENGINES ), 3) IT IS NO LONGER UPDATED

BZR_PATH="/bzr/mysql-5.7.7-rc-linux-glibc2.5-x86_64/mysql-test"

# Ideas for improvement
# - Scan original MTR file for multi-line statements and reconstruct (tr '\n' ' ' for example) to avoid half-statements ending up in resulting file
# - Change generic table names (for example t1) to _table for RQG/yy file purposes only
# - Also parse opt files for options to use (randomly)

if [ ! -r ${BZR_PATH}/t/1st.test ]; then
  echo "Something is wrong; this script cannot locate/read ${BZR_PATH}/t/1st.test"
  echo "You may want to check the BZR_PATH setting at the top of this script (currently set to '${BZR_PATH}')"
  exit 1
fi
if [ "$1" == "" -o "$1" == "2" ]; then
  VERSION=2  # Much improved version which uses .result files. Also generates/completes much faster (now the default)
else
  VERSION=1  # Backwards compatible option, use .test files. A good alternative generator. The two files could even be combined.
fi

rm -f /tmp/mtr_to_sql.[prep12y]*
touch /tmp/mtr_to_sql.prep1
touch /tmp/mtr_to_sql.prep2
touch /tmp/mtr_to_sql.yy

# Filter list
# -----------
# * Not scanning for "^REVOKE " commands as these drop access and this hinders CLI/pquery testing. However, REVOKE may work for RQG/yy (TBD)
# * egrep -vi Inline filters
#   * 'strict': this causes corruption bugs - see http://dev.mysql.com/doc/refman/5.6/en/innodb-parameters.html#sysvar_innodb_checksum_algorithm
#   * 'innodb_track_redo_log_now'  - https://bugs.launchpad.net/percona-server/+bug/1368530
#   * 'innodb_log_checkpoint_now'  - https://bugs.launchpad.net/percona-server/+bug/1369357 (dup of 1368530)
#   * 'innodb_purge_stop_now'      - https://bugs.launchpad.net/percona-server/+bug/1368552
#   * 'innodb_track_changed_pages' - https://bugs.launchpad.net/percona-server/+bug/1368530
#   * global/session debug         - https://bugs.launchpad.net/percona-server/+bug/1372675

if [ $VERSION -eq 1 ]; then
  egrep --binary-files=text -ih "^SELECT |^INSERT |^UPDATE |^DROP |^CREATE |^RENAME |^TRUNCATE |^REPLACE |^START |^SAVEPOINT |^ROLLBACK |^RELEASE |^LOCK |^XA |^PURGE |^RESET |^SHOW |^CHANGE |^START |^STOP |^PREPARE |^EXECUTE |^DEALLOCATE |^BEGIN |^DECLARE |^FETCH |^CASE |^IF |^ITERATE |^LEAVE |^LOOP |^REPEAT |^RETURN |^WHILE |^CLOSE |^GET |^RESIGNAL |^SIGNAL |^EXPLAIN |^DESCRIBE |^HELP |^USE |^GRANT |^ANALYZE |^CHECK |^CHECKSUM |^OPTIMIZE |^REPAIR |^INSTALL |^UNINSTALL |^BINLOG |^CACHE |^FLUSH |^KILL |^LOAD |^CALL |^DELETE |^DO |^HANDLER |^LOAD DATA |^LOAD XML |^ALTER |^SET " ${BZR_PATH}/*/*.test ${BZR_PATH}/*/*/*.test ${BZR_PATH}/*/*/*/*.test ${BZR_PATH}/*/*/*/*/*.test | \
   egrep --binary-files=text -vi "Is a directory" | \
   sort -u | \
    grep --binary-files=text -vi "strict" | \
    grep --binary-files=text -vi "innodb[-_]track[-_]redo[-_]log[-_]now" | \
    grep --binary-files=text -vi "innodb[-_]log[-_]checkpoint[-_]now" | \
    grep --binary-files=text -vi "innodb[-_]purge[-_]stop[-_]now" | \
    grep --binary-files=text -vi "set[ @globalsession\.\t]*innodb[-_]track_changed[-_]pages[ \.\t]*=" | \
    grep --binary-files=text -vi "yfos" | \
    grep --binary-files=text -vi "set[ @globalsession\.\t]*debug[ \.\t]*=" | \
   sed 's/.*[^;]$//' | grep --binary-files=text -v "^$" | \
   sed 's/$/ ;;;/' | sed 's/[ \t;]*$/;/' | \
   shuf --random-source=/dev/urandom | \
   awk '{print "q"NR" | " >> "/tmp/mtr_to_sql.prep1";
         print "q"NR": "$0 >> "/tmp/mtr_to_sql.prep2"}'

  cat /tmp/mtr_to_sql.prep1 | tr '\n' ' ' | sed 's/^/query: /;s/[ |]*$/ ;/' > /tmp/mtr_to_sql.yy
  echo "" >> /tmp/mtr_to_sql.yy
  cat /tmp/mtr_to_sql.prep2 >> /tmp/mtr_to_sql.yy
  rm -f /tmp/mtr_to_sql.prep1 /tmp/mtr_to_sql.prep2
else  # New version 2
  # Tabs are filtered, as they are highly likely CLI result output
  # First two sed lines (change | and $$ to ;) are significant changes, more review/testing later may show better solutions
  cat ${BZR_PATH}/*/*.test ${BZR_PATH}/*/*/*.test ${BZR_PATH}/*/*/*/*.test ${BZR_PATH}/*/*/*/*/*.test | \
   sed 's/|/;\n/g' | \
   sed 's/$$/;\n/g' | \
   sed 's|\t|FILTERTHIS|' | \
   sed 's|^ERROR |FILTERTHIS|i' | \
   sed 's|^Warning|FILTERTHIS|i' | \
   sed 's|^Note|FILTERTHIS|i' | \
   sed 's|^Got one of the listed errors|FILTERTHIS|i' | \
   sed 's|^variable_value|FILTERTHIS|i' | \
   sed 's|^Antelope|FILTERTHIS|i' | \
   sed 's|^Barracuda|FILTERTHIS|i' | \
   sed 's|^count|FILTERTHIS|i' | \
   sed 's|^source.*include.*inc|FILTERTHIS|i' | \
   sed 's|^#|FILTERTHIS|' | \
   sed 's|^\-\-|FILTERTHIS|' | \
   sed 's|^@|FILTERTHIS|' | \
   sed 's|^{|FILTERTHIS|' | \
   sed 's|^\*|FILTERTHIS|' | \
   sed 's|^"|FILTERTHIS|' | \
   sed 's|ENGINE[= \t]*NDB|ENGINE=INNODB|gi' | \
   sed 's|^.$|FILTERTHIS|' | sed 's|^..$|FILTERTHIS|' | sed 's|^...$|FILTERTHIS|' | \
   sed 's|^[-0-9]*$|FILTERTHIS|' | sed 's|^c[0-9]*$|FILTERTHIS|' | sed 's|^t[0-9]*$|FILTERTHIS|' | \
   grep --binary-files=text -v "FILTERTHIS" | tr '\n' ' ' | sed 's|;|;\n|g;s|//|//\n|g;s/END\([|]\+\)/END\1\n/g;' | \
   sort -u | \
    grep --binary-files=text -vi "^Ob%&0Z_" | \
    grep --binary-files=text -vi "^E/TB/]o" | \
    grep --binary-files=text -vi "^no cipher request crashed" | \
    grep --binary-files=text -vi "^[ \t]*DELIMITER" | \
    grep --binary-files=text -vi "^[ \t]*KILL" | \
    grep --binary-files=text -vi "^[ \t]*REVOKE" | \
    grep --binary-files=text -vi "^[ \t]*[<>{}()\.\@\*\+\^\#\!\\\/\'\`\"\;\:\~\$\%\&\|\+\=0-9]" | \
    grep --binary-files=text -vi "\\\q" | \
    grep --binary-files=text -vi "\\\r" | \
    grep --binary-files=text -vi "\\\u" | \
    grep --binary-files=text -vi "^[ \t]*.[ \t]*$" | \
    grep --binary-files=text -vi "^[ \t]*..[ \t]*$" | \
    grep --binary-files=text -vi "^[ \t]*...[ \t]*$" | \
    grep --binary-files=text -vi "^[ \t]*\-\-" | \
    grep --binary-files=text -vi "^[ \t]*while.*let" | \
    grep --binary-files=text -vi "^[ \t]*let" | \
    grep --binary-files=text -vi "^[ \t]*while.*connect" | \
    grep --binary-files=text -vi "^[ \t]*connect" | \
    grep --binary-files=text -vi "^[ \t]*while.*disconnect" | \
    grep --binary-files=text -vi "^[ \t]*disconnect" | \
    grep --binary-files=text -vi "^[ \t]*while.*eval" | \
    grep --binary-files=text -vi "^[ \t]*eval" | \
    grep --binary-files=text -vi "^[ \t]*while.*find" | \
    grep --binary-files=text -vi "^[ \t]*find" | \
    grep --binary-files=text -vi "^[ \t]*while.*exit" | \
    grep --binary-files=text -vi "^[ \t]*exit" | \
    grep --binary-files=text -vi "^[ \t]*while.*send" | \
    grep --binary-files=text -vi "^[ \t]*send" | \
    grep --binary-files=text -vi "^[ \t]*file_exists" | \
    grep --binary-files=text -vi "^[ \t]*enable_info" | \
    grep --binary-files=text -vi "^[ \t]*call mtr.add_suppression" | \
    grep --binary-files=text -vi "strict" | \
    grep --binary-files=text -vi "innodb[-_]track[-_]redo[-_]log[-_]now" | \
    grep --binary-files=text -vi "innodb[-_]log[-_]checkpoint[-_]now" | \
    grep --binary-files=text -vi "innodb[-_]purge[-_]stop[-_]now" | \
    grep --binary-files=text -vi "innodb[-_]fil[-_]make[-_]page[-_]dirty[-_]debug" | \
    grep --binary-files=text -vi "set[ @globalsession\.\t]*innodb[-_]track_changed[-_]pages[ \.\t]*=" | \
    grep --binary-files=text -vi "yfos" | \
    grep --binary-files=text -vi "set[ @globalsession\.\t]*debug[ \.\t]*=" | \
    grep --binary-files=text -v "^[# \t]$" | grep --binary-files=text -v "^#" | \
   sed 's/$/ ;;;/' | sed 's/[ \t;]\+$/;/' | sed 's|^[ \t]\+||;s|[ \t]\+| |g' | \
   sed 's/^[|]\+ //' | sed 's///g' | \
   shuf --random-source=/dev/urandom | \
   sed 's|end//;|end //;|gi' | \
   sed 's| t[0-9]\+ | t1 |gi' | \
   sed 's|mysqltest[\.0-9]*@|user@|gi' | \
   sed 's|mysqltest[\.0-9]*||gi' | \
   sed 's|user@|mysqltest@|gi' | \
   sed 's| .*mysqltest.*@| mysqltest@|gi' | \
   sed 's| test.[a-z]\+[0-9]\+[( ]\+| t1 |gi' | \
   sed 's| INTO[ \t]*[a-z]\+[0-9]\+| INTO t1 |gi' | \
   sed 's| TABLE[ \t]*[a-z]\+[0-9]\+\([;( ]\+\)| TABLE t1\1|gi' | \
   sed 's| PROCEDURE[ \t]*[psroc_-]\+[0-9]*[( ]\+| PROCEDURE p1(|gi' | \
   sed 's| FROM[ \t]*[a-z]\+[0-9]\+| FROM t1 |gi' | \
   sed 's|DROP PROCEDURE IF EXISTS .*;|DROP PROCEDURE IF EXISTS p1;|gi' | \
   sed 's|CREATE PROCEDURE.*BEGIN END;|CREATE PROCEDURE p1() BEGIN END;|gi' | \
   sed 's|^USE .*|USE test;|gi' | \
   grep --binary-files=text -v "/^[^A-Z][^ ]\+$" | \
   awk '{print "q"NR" | " >> "/tmp/mtr_to_sql.prep1";
         print "q"NR": "$0 >> "/tmp/mtr_to_sql.prep2";}'

  cat /tmp/mtr_to_sql.prep1 | tr '\n' ' ' | sed 's/^/query: /;s/[ |]*$/ ;/' > /tmp/mtr_to_sql.yy
  echo "" >> /tmp/mtr_to_sql.yy
  cat /tmp/mtr_to_sql.prep2 >> /tmp/mtr_to_sql.yy
  rm -f /tmp/mtr_to_sql.prep1 /tmp/mtr_to_sql.prep2
fi

echo "Done! Generated /tmp/mtr_to_sql.yy for RQG"
