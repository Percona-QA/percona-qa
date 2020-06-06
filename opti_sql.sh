#!/bin/bash

if [ ! -r new-main-md.sql ]; then echo "./new-main-md.sql not found!"; exit 1; fi

mkdir -p optisql
rm -f optisql/optisql.sql.tmp
touch optisql/optisql.sql.tmp
grep --binary-files=text -iE "^CREATE TABLE " new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^DROP TABLE "   new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^INSERT INTO "  new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^UPDATE "       new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^DELETE FROM "  new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^ALTER TABLE "  new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^TRUNCATE "     new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^SELECT "       new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^LOCK TABLE"    new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
grep --binary-files=text -iE "^FLUSH"         new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
#grep --binary-files=text -iE "^EXPLAIN "      new-main-md.sql | sed -e 's|t[2-9]|t|g' >> optisql/optisql.sql.tmp
# The first two selectors of the grep exclude SET GLOBAL/SESSION with allocations > approx 5GB. This
# prevents most OOM issues due to over-allocations like SET GLOBAL key_buffer_size=1125899906842624;
cat optisql/optisql.sql.tmp | \
  grep --binary-files=text -Evi "SET.*[GS][LE][OS][BS][AI][LO].*=.*[6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|SET.*[GS][LE][OS][BS][AI][LO].*=.*[0-9][6-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]|CHARSET|CHARACTER|utf|latin|ucs|hp|bin|cp|ascii|sjis|ujis|ci|\@|JSON" | \
  LANG=C sed -e 's|[\d128-\d255]|c|g' | \
  sed -e 's|\t| |g' | \
  sed -e 's|$|;|;s|;[ ]*;$|;|g' | \
  sed -e 's|`|c|g' | \
  sed -e 's|\\c|c|g;s|cc\+|c|g' | \
  sed -e 's|t1|t|g' | \
  sed -e 's|ALTER[ ]\+TABLE[ ]\+[^ (]\+|ALTER TABLE t |' | \
  sed -e 's|CREATE[ ]\+TABLE[ ]\+[^ (]\+|CREATE TABLE t |' | \
  sed -e 's|DROP[ ]\+TABLE[ ]\+[^ (]\+|DROP TABLE t |' | \
  sed -e 's|SELECT\([^F]\+\)FROM[ ]\+[^ ]\+|SELECT \1 FROM t |' | \
  sed -e 's|Aria|InnoDB|gi' | \
  sed -e 's|CSV|InnoDB|gi' | \
  sed -e 's|MEMORY|InnoDB|gi' | \
  sed -e 's|HEAP|InnoDB|gi' | \
  sed -e 's|$ENGINE|InnoDB|gi' | \
  sed -e 's|MyISAM|InnoDB|gi' | \
  sed -e 's|SEQUENCE|InnoDB|gi' | \
  sed -e 's|NDB|InnoDB|gi' | \
  sed -e 's|RocksDB|InnoDB|gi' | \
  sed -e 's|TokuDB|InnoDB|gi' | \
  sed -e 's|MRG_MyISAM|InnoDB|gi' | \
  sed -e 's|MRG_MEMORY|InnoDB|gi' | \
  sed -e 's|MRG_RocksDB|InnoDB|gi' | \
  sed -e 's|RocksDBcluster|InnoDB|gi' | \
  sed -e 's|MEMORYcluster|InnoDB|gi' | \
  sed -e 's|Merge.*UNION|InnoDB|gi' | \
  sed -e 's|MERGE|InnoDB|gi' | \
  sed -e 's|InnoDB|InnoDB|gi' | \
  sed -e 's|CREATE|\U\0|gi;s|TABLE|\U\0|gi;s|INSERT|\U\0|gi;s|INTO|\U\0|gi;s|UPDATE|\U\0|gi;s|DELETE|\U\0|gi;s|FROM|\U\0|gi;s|ALTER|\U\0|gi;s|TRUNCATE|\U\0|gi;s|SELECT|\U\0|gi;s|LOCK|\U\0|gi;s|EXPLAIN|\U\0|gi;s|INDEX|\U\0|gi;s|INT|\U\0|gi;s|BLOB|\U\0|gi;s|TINY|\U\0|gi;s|CHAR|\U\0|gi;s|BIT|\U\0|gi;s|ENUM|\U\0|gi;s|NOT|\U\0|gi;s|NULL|\U\0|gi;s|DEFAULT|\U\0|gi;s|ENGINE|\U\0|gi;s|TIMESTAMP|\U\0|gi;s|INTEGER|\U\0|gi;s|TEXT|\U\0|gi;s|SMALL|\U\0|gi;s|LARGE|\U\0|gi;s|SET|\U\0|gi;s|PRIMARY|\U\0|gi;s|MEDIUM|\U\0|gi;s|KEY|\U\0|gi;s|HASH|\U\0|gi;s|VARCHAR|\U\0|gi;s|EXISTS|\U\0|gi;s|IF NOT|\U\0|gi;s|UNIQUE|\U\0|gi;s|YEAR|\U\0|gi;s|MONTH|\U\0|gi;s|DATE|\U\0|gi;s|DAY|\U\0|gi;s|BIG|\U\0|gi;s|DOUBLE|\U\0|gi;s|FIXED|\U\0|gi;s|COMMIT|\U\0|gi;s|WHERE|\U\0|gi;s|AND|\U\0|gi;s|NOT IN|\U\0|gi;s|XOR|\U\0|gi;s| IN |\U\0|gi;s|MAX|\U\0|gi;s|MIN|\U\0|gi;s|COUNT|\U\0|gi;s|GROUP BY|\U\0|gi;s|ORDER BY|\U\0|gi;s|MOD|\U\0|gi;s| AS |\U\0|gi;' | \
  sed -e 's|[ ]\+| |g' \
 > optisql/optisql.sql   # ^ Note there is no pipe here
rm -f optisql/optisql.sql.tmp
