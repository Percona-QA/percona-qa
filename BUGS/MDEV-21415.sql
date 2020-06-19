# Keep repeating the following testcase in quick succession till mysqld crashes. Definitely sporadic.
DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE TABLE t (column_name_1 INT, column_name_2 VARCHAR(52)) ENGINE=InnoDB;
XA START 'a';
SET MAX_STATEMENT_TIME = 0.001;
INSERT INTO t VALUES (101,NULL),(102,NULL),(103,NULL),(104,NULL),(105,NULL),(106,NULL),(107,NULL),(108,NULL),(109,NULL),(1010,NULL);
CHECKSUM TABLE t, INFORMATION_SCHEMA.tables;
SELECT SLEEP(3);

CREATE TABLE t1 ( c1 int, c2 int, c3 int, c4 int, c5 int, key (c1), key (c5)) ENGINE=InnoDB;
INSERT INTO t1 VALUES (NULL, 15, NULL, 2012, NULL) , (NULL, 12, 2008, 2004, 2021) , (2003, 11, 2031, NULL, NULL);
CREATE TABLE t2 SELECT c2 AS f FROM t1;
UPDATE t2 SET f = 0 WHERE f NOT IN ( SELECT c2 AS c1 FROM t1 WHERE c5 IS NULL AND c1 IS NULL );
