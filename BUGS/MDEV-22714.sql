CREATE TABLE t1 (a INT) ENGINE=InnoDB;
INSERT INTO t1 VALUES (0),(NULL),(0);
CREATE TABLE t2 (f INT, s DATE, e DATE, PERIOD FOR p(s,e), UNIQUE(f, p WITHOUT OVERLAPS)) ENGINE=InnoDB;
INSERT INTO t2 VALUES (NULL,'2026-02-12','2036-09-16'), (NULL,'2025-03-09','2032-12-05');
UPDATE IGNORE t1 JOIN t2 SET f = a;

# mysqld options that were in use during reduction: --sql_mode=ONLY_FULL_GROUP_BY --performance-schema --performance-schema-instrument='%=on' --default-tmp-storage-engine=MyISAM --innodb_file_per_table=1 --innodb_flush_method=O_DIRECT
USE test;
CREATE TABLE t1(a BIGINT UNSIGNED) ENGINE=InnoDB;
set global innodb_limit_optimistic_insert_debug = 2;
INSERT INTO t1 VALUES(12979);
ALTER TABLE t1 algorithm=inplace, ADD f DECIMAL(5,2);
insert into t1 values (5175,'abcdefghijklmnopqrstuvwxyz');
DELETE FROM t1;
SELECT HEX(a), HEX(@a:=CONVERT(a USING utf8mb4)), HEX(CONVERT(@a USING utf16le)) FROM t1; ;
