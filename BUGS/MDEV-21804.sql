# mysqld options required for replay: --log-bin --sql_mode= 
USE test;
SET @@SESSION.BINLOG_ROW_IMAGE=NOBLOB;
CREATE TEMPORARY TABLE t1 (c1 INT,c2 INT);
CREATE TABLE t2(c1 INT KEY,c2 TEXT UNIQUE);
UPDATE performance_schema.setup_objects SET ENABLED=0;
INSERT INTO t2 VALUES(0,0);

# mysqld options required for replay:  --log-bin --sql_mode=
USE test;
CREATE TEMPORARY TABLE t (c INT PRIMARY KEY, c2 BLOB UNIQUE);
SET @@SESSION.binlog_row_image=noblob;
SELECT * FROM performance_schema.hosts;
INSERT INTO t VALUES(0,0);

# mysqld options required for replay:  --log-bin --sql_mode=
USE test;
SET binlog_row_image= NOBLOB;
CREATE TABLE t1 (pk INT PRIMARY KEY, a TEXT, UNIQUE(a));
INSERT INTO t1 VALUES (1,'foo');
