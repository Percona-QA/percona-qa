# mysqld options required for replay: --log-bin --sql_mode= 
USE test;
SET @@SESSION.BINLOG_ROW_IMAGE=NOBLOB;
CREATE TEMPORARY TABLE t1 (c1 INT,c2 INT);
CREATE TABLE t2(c1 INT KEY,c2 TEXT UNIQUE);
UPDATE performance_schema.setup_objects SET ENABLED=0;
INSERT INTO t2 VALUES(0,0);
