USE test;
SET tmp_table_size=1024;
SET tmp_disk_table_size=1024;
CREATE TABLE t1 (x INT(11), row_start BIGINT(20) UNSIGNED GENERATED ALWAYS AS ROW START INVISIBLE, row_end BIGINT(20) UNSIGNED GENERATED ALWAYS AS ROW END INVISIBLE, PERIOD FOR SYSTEM_TIME (row_start, row_end)) WITH SYSTEM VERSIONING;
INSERT INTO t1 VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1);
SELECT * FROM t1 INTERSECT ALL SELECT * FROM t1 INTERSECT ALL SELECT * FROM t1;

