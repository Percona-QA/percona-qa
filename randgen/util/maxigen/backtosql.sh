# Created by Roel Van de Paar, Percona LLC

# Possible improvements
# - Add random integer selection, or even use NULL etc.
# - c1=c1 should become something like c1=c2 and more columns available

cat *.yy | \
 sort -u | \
 sed "s|\@kill_id|2|g" | \
 egrep -v "^query|{|}" | grep -v "KILL[ \t]\+[^Q]" | \
 sed "s|/\*[^!].*\*/||" | \
 sed 's/|[ \t]*$/;/' | sed "s|;[ \t]*$|DUMMYDUM|" | tr ';' '\n' | sed "s|DUMMYDUM|;|;s|[; \t]*$|;|;s|^[ \t]*||" | \
 sed "s|\[invariant\]||g" | \
 sed "s|_unsigned||g" | \
 sed "s|_list||g" | \
 sed "s|_key||g" | \
 sed "s|_nokey||g" | \
 sed "s|_indexed||g" | \
 sed "s|_no_pk||g" | \
 sed "s|_next||g" | \
 sed "s|_name||g" | \
 sed "s|_table|t1|g" | \
 sed "s| AA | t1 |g;s| BB | t1 |g;s| CC | t1 |g;s| DD | t1 |g;s| EE | t1 |g;s| FF | t1 |g;s| GG | t1 |g;s| HH | t1 |g;s| II | t1 |g;s| JJ | t1 |g;" | \
 sed "s|/smf_[a-z_]\+|t1|g" | \
 sed "s|[GRAND]*PARENT[0-9]*|t1|g" | \
 sed "s|CHILD[0-9]*|t1|g" | \
 sed "s| digit|0|g;s|_digit|0|g" | \
 sed "s| letter|a|g;s|_letter|a|g" | \
 sed "s|col_[a-z0-9_]\+|c1|g;s|_field|c1|g;s|field[0-9]*|c1|g" | \
 sed "s|_field_count|0|g" | \
 sed "s|/WHERE [a-z_0-9]\+|WHERE c1|g" | \
 sed "s|UPDATE [a-z0-9_]\+[. ]\+[a-z0-9_]\+ |UPDATE t1 |g" | \
 sed "s|UPDATE [a-z0-9_]\+ |UPDATE t1 |g" | \
 sed "s|INTO [a-z0-9_]\+[. ]\+[a-z0-9_]\+ |INTO t1 |g;s|INTO [a-z0-9_]\+ |INTO t1 |g" | \
 sed "s|FROM [a-z0-9_]\+[. ]\+[a-z0-9_]\+ |FROM t1 |g;s|FROM [a-z0-9_]\+ |FROM t1 |g" | \
 sed "s|JOIN [a-z0-9_]\+[. ]\+[a-z0-9_]\+ |JOIN c1 |g;s|JOIN [a-z0-9_]\+ |JOIN c1 |g" | \
 sed "s|ON ([a-z0-9_ ]\+[=><]\+[a-z0-9_ ]\+[AND a-z0-9_=><]*)|ON (c1=c1)|g" | \
 sed "s|WHERE [a-z0-9_]\+[. ]\+[a-z0-9_]\+ |WHERE c1 |g;s|WHERE [a-z0-9_]\+ |WHERE c1 |g" | \
 sed "s|WHERE [a-z0-9_]\+[=>< ]\+[a-z0-9_]\+|WHERE c1=c1|g" | \
 sed "s|AND [a-z0-9_]\+[=>< ]\+[a-z0-9_]\+|AND c1<0|g" | \
 sed "s|TABLE [a-z0-9_]\+[. ]\+[a-z0-9_]\+ |TABLE t1 |g" | \
 sed "s|TABLE [a-z0-9_]\+ |TABLE t1 |g" | \
 sed "s|_int|0|g" | \
 sed "s|_smallint|0|g" | \
 sed "s|_tinyint|0|g" | \
 sed "s|_integer|0|g" | \
 sed "s|_mediumint|0|g" | \
 sed "s|_bigint|0|g" | \
 sed "s|_binary|'1'|g" | \
 sed "s|_text|'a'|g" | \
 sed "s|_char[()0-9]*|'a'|g" | \
 sed "s|_varchar[()0-9]*|'a'|g" | \
 sed "s|_datetime|2038-01-20 03:14:08|g" | \
 sed "s|_timestamp|2038-01-20 03:14:08|g" | \
 sed "s|_thread_count|1|g" | \
 sed "s|_thread_id|1|g" | \
 sed "s|_set|'a,b,c'|g" | \
 sed "s|_database|test|g" | \
 sed "s|_time|23:59:59|g" | \
 sed "s|_english|'a'|g" | \
 sed "s|_states|'a'|g" | \
 sed "s|_year|1960|g" | \
 sed "s|_date|'2038-01-20'|g" | \
 sed "s|_bool|1|g" | \
 sed "s|_bit[()0-9]*|'01010101010'|g" | \
 sed "s|_bit|'0'|g" | \
 sed "s|_hex[()0-9]\+|x'0'|g" | \
 sed "s|_hex|x'0000'|g" | \
 sed "s|_quid|'aaaaa'|g" | \
 sed "s|_cwd|${PWD}|g" | \
 sed "s|_tmpnam|'a'|g" | \
 sed "s|_unix_timestamp|$(date +%s)|g" | \
 sed "s|_pid|$(echo $$)|g" | \
 sed "s|_charset|ujis|g" | \
 sed "s|_collation|ujis_bin|g" | \
 sed "s|_data|NULL|g" | \
 sed "s|LIMIT0|LIMIT 1|g" | \
 sed "s|  | |g;s|  | |g;s|  | |g" | \
 sed "0~10 s|$|\nDROP TABLE IF EXISTS t1;|" | \
 sed "0~30 s|$|\nCREATE TABLE t1 (c1 INT, pk int PRIMARY KEY);|"  | \
 sed "0~30 s|$|\nCREATE TABLE t1 (c1 DATETIME, pk int PRIMARY KEY AUTO_INCREMENT);|" | \
 sed "0~30 s|$|\nCREATE TABLE t1 (c1 TIMESTAMP, pk int PRIMARY KEY);|" | \
 sed "0~30 s|$|\nCREATE TABLE t1 (c1 BINARY, pk int PRIMARY KEY);|" | \
 sed "0~30 s|$|\nCREATE TABLE t1 (c1 TEXT, pk int PRIMARY KEY);|" | \
 sed "0~30 s|$|\nCREATE TABLE t1 (c1 BLOB, pk int PRIMARY KEY);|" > outnew.sql

for i in $(seq 1 10); do
  echo "SET AUTOCOMMIT=ON;" >> outnew.sql
  echo "COMMIT;" >> outnew.sql
  echo "COMMIT AND CHAIN;" >> outnew.sql
  echo "COMMIT AND CHAIN NO RELEASE;" >> outnew.sql
  echo "COMMIT AND CHAIN RELEASE;" >> outnew.sql
  echo "COMMIT AND NO CHAIN;" >> outnew.sql
  echo "COMMIT AND NO CHAIN NO RELEASE;" >> outnew.sql
  echo "COMMIT AND NO CHAIN RELEASE;" >> outnew.sql
  echo "FLUSH BINARY LOGS;" >> outnew.sql
  echo "FLUSH DES_KEY_FILE;" >> outnew.sql
  echo "FLUSH ENGINE LOGS;" >> outnew.sql
  echo "FLUSH ERROR LOGS;" >> outnew.sql
  echo "FLUSH GENERAL LOGS;" >> outnew.sql
  echo "FLUSH HOSTS;" >> outnew.sql
  echo "FLUSH LOCAL BINARY LOGS;" >> outnew.sql
  echo "FLUSH LOCAL DES_KEY_FILE;" >> outnew.sql
  echo "FLUSH LOCAL ENGINE LOGS;" >> outnew.sql
  echo "FLUSH LOCAL ERROR LOGS;" >> outnew.sql
  echo "FLUSH LOCAL GENERAL LOGS;" >> outnew.sql
  echo "FLUSH LOCAL HOSTS;" >> outnew.sql
  echo "FLUSH LOCAL LOGS;" >> outnew.sql
  echo "FLUSH LOCAL PRIVILEGES;" >> outnew.sql
  echo "FLUSH LOCAL QUERY CACHE;" >> outnew.sql
  echo "FLUSH LOCAL RELAY LOGS;" >> outnew.sql
  echo "FLUSH LOCAL SLOW LOGS;" >> outnew.sql
  echo "FLUSH LOCAL STATUS;" >> outnew.sql
  echo "FLUSH LOCAL TABLES;" >> outnew.sql
  echo "FLUSH LOCAL TABLES t1;" >> outnew.sql
  echo "FLUSH LOCAL TABLES t1 FOR EXPORT;" >> outnew.sql
  echo "FLUSH LOCAL TABLES t1 WITH READ LOCK;" >> outnew.sql
  echo "FLUSH LOCAL TABLES t2;" >> outnew.sql
  echo "FLUSH LOCAL TABLES t2 FOR EXPORT;" >> outnew.sql
  echo "FLUSH LOCAL TABLES t2 WITH READ LOCK;" >> outnew.sql
  echo "FLUSH LOCAL TABLES WITH READ LOCK;" >> outnew.sql
  echo "FLUSH LOCAL USER_RESOURCES;" >> outnew.sql
  echo "FLUSH LOGS;" >> outnew.sql
  echo "FLUSH PRIVILEGES;" >> outnew.sql
  echo "FLUSH QUERY CACHE;" >> outnew.sql
  echo "FLUSH RELAY LOGS;" >> outnew.sql
  echo "FLUSH SLOW LOGS;" >> outnew.sql
  echo "FLUSH STATUS;" >> outnew.sql
  echo "FLUSH TABLES;" >> outnew.sql
  echo "FLUSH TABLES t1;" >> outnew.sql
  echo "FLUSH TABLES t1 FOR EXPORT;" >> outnew.sql
  echo "FLUSH TABLES t1 WITH READ LOCK;" >> outnew.sql
  echo "FLUSH TABLES t2;" >> outnew.sql
  echo "FLUSH TABLES t2 FOR EXPORT;" >> outnew.sql
  echo "FLUSH TABLES t2 WITH READ LOCK;" >> outnew.sql
  echo "FLUSH TABLES WITH READ LOCK;" >> outnew.sql
  echo "FLUSH USER_RESOURCES;" >> outnew.sql
  echo "LOCK TABLES t1 AS t2 LOW_PRIORITY WRITE;" >> outnew.sql
  echo "LOCK TABLES t1 AS t2 READ;" >> outnew.sql
  echo "LOCK TABLES t1 AS t2 READ LOCAL;" >> outnew.sql
  echo "LOCK TABLES t1 AS t2 WRITE;" >> outnew.sql
  echo "LOCK TABLES t1 LOW_PRIORITY WRITE;" >> outnew.sql
  echo "LOCK TABLES t1 READ;" >> outnew.sql
  echo "LOCK TABLES t1 READ LOCAL;" >> outnew.sql
  echo "LOCK TABLES t1 WRITE;" >> outnew.sql
  echo "RESET MASTER;" >> outnew.sql
  echo "RESET SLAVE;" >> outnew.sql
  echo "SET AUTOCOMMIT = 0;" >> outnew.sql
  echo "SET AUTOCOMMIT = 1;" >> outnew.sql
  echo "SET AUTOCOMMIT = ON;" >> outnew.sql
  echo "SET AUTOCOMMIT = OFF;" >> outnew.sql
  echo "SET GLOBAL TRANSACTION ISOLATION LEVEL READ COMMITTED;" >> outnew.sql
  echo "SET GLOBAL TRANSACTION ISOLATION LEVEL REPEATABLE READ;" >> outnew.sql
  echo "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;" >> outnew.sql
  echo "SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;" >> outnew.sql
  echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;" >> outnew.sql
  echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ WRITE;" >> outnew.sql
  echo "SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE;" >> outnew.sql
  echo "SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ ONLY;" >> outnew.sql
  echo "SET SESSION TRANSACTION READ ONLY, ISOLATION LEVEL REPEATABLE READ;" >> outnew.sql
  echo "SET SESSION TRANSACTION READ ONLY, ISOLATION LEVEL SERIALIZABLE;" >> outnew.sql
  echo "SET SESSION TRANSACTION READ WRITE, ISOLATION LEVEL REPEATABLE READ;" >> outnew.sql
  echo "SET TRANSACTION ISOLATION LEVEL READ COMMITTED;" >> outnew.sql
  echo "SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;" >> outnew.sql
  echo "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;" >> outnew.sql
  echo "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;" >> outnew.sql
  echo "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ ONLY;" >> outnew.sql
  echo "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ WRITE;" >> outnew.sql
  echo "SET TRANSACTION READ ONLY, ISOLATION LEVEL READ COMMITTED;" >> outnew.sql
  echo "SET TRANSACTION READ WRITE, ISOLATION LEVEL READ COMMITTED;" >> outnew.sql
  echo "START TRANSACTION;" >> outnew.sql
  echo "START TRANSACTION READ ONLY;" >> outnew.sql
  echo "START TRANSACTION READ WRITE;" >> outnew.sql
  echo "START TRANSACTION WITH CONSISTENT SNAPSHOT;" >> outnew.sql
  echo "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY;" >> outnew.sql
  echo "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ WRITE;" >> outnew.sql
  echo "UNLOCK TABLES;" >> outnew.sql
done
