# Run in continually random SQL order, using 150 or 200 threads, perpetually
# About 50k-500k executions, and sufficient time to hit the 600sec timeout are necessary
DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE TABLE t1 (a INT) ENGINE=InnoDB;
INSERT INTO t1 VALUES (NULL);
XA BEGIN 'x';
UPDATE t1 SET a = 1;
DELETE FROM t1;
ALTER TABLE t1 ADD COLUMN extra INT;
INSERT INTO t1 (a) VALUES (2);
ROLLBACK;
DELETE FROM t1;
INSERT INTO t1 (a) VALUES (2);
XA END 'x';
XA ROLLBACK 'x';
DROP TABLE t1;
