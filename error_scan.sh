#!/bin/bash
# Created by Roel Van de Paar, Percona LLC

grep --binary-files=text -i "ERROR" */log/master.err | \
  grep --binary-files=text -vi "Plugin keyring_vault reported.*not found" | \
  grep --binary-files=text -vi "MYSQL_BIN_LOG::purge_logs was called with file.*not listed in the index" | \
  grep --binary-files=text -vi "User stopword table test/user_stopword does not exist" | \
  grep --binary-files=text -vi "Encryption can't find master key, please check the keyring plugin is loaded" | \
  grep --binary-files=text -vi "Event Scheduler:.*Cannot execute statement in a READ ONLY transaction." | \
  grep --binary-files=text -vi "Event Scheduler:.*Table.*doesn't exist" | \
  grep --binary-files=text -vi "Event Scheduler:.*execution failed, failed to authenticate the user." | \
  grep --binary-files=text -vi "Event Scheduler:.*The user specified as a definer.*does not exist" | \
  grep --binary-files=text -vi "Event Scheduler:.*You have an error in your SQL syntax; check the manual that corresponds" | \
  grep --binary-files=text -vi "User stopword table.*does not exist" | \
  grep --binary-files=text -vi ".Server. unknown variable '.*'." | \
  grep --binary-files=text -vi "mysqlx r.*Setup of socket:.*failed, another process with PID.*is using UNIX socket file" | \
  grep --binary-files=text -vi "mysqlx r.*Setup of bind-address:.*failed,.*failed with error: Address already in use (98). Do" | \
  grep --binary-files=text -vi "mysqlx r.*Preparation of I/O interfaces failed, X Protocol won't be accessible'" | \
  grep --binary-files=text -vi "Cannot add field.*in table.*because.*the row size is.*greater than maximum.*index leaf page" | \
  grep --binary-files=text -vi "Threadpool could not create additional thread to handle queries, because.*threads was reached." | \
  grep --binary-files=text -vi "Out of sort memory, consider increasing server sort buffer size!" | \
  grep --binary-files=text -vi "Cannot save index statistics for table.*, index.*, stat name.*: Lock wait timeout" | \
  sed "s|master.err:.*\[ERROR\]|master.err:[ERROR]|" | \
  sed "s|master.err:.*\[Warning\]|master.err:[Warning]|" | \
  sort -u
