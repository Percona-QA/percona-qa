USE test;
SET SESSION aria_sort_buffer_size=1023;
CREATE TABLE t (c CHAR);
INSERT INTO t VALUES (''),('');
CREATE TABLE t2 (c TEXT,INDEX(c)) ENGINE=Aria;
INSERT INTO t2 SELECT * FROM t;

USE test;
SET SESSION aria_sort_buffer_size=1023;
CREATE TABLE t (c CHAR);
INSERT INTO t VALUES (''),('');
SELECT * FROM t INTO OUTFILE 'o';
CREATE TABLE t2 (c TEXT,INDEX(c)) ENGINE=Aria;
LOAD DATA INFILE 'o' INTO TABLE t2;

SET aria_sort_buffer_size=4096;
SET SESSION tmp_table_size = 65535;
SELECT COUNT(*) FROM information_schema.tables A WHERE NOT EXISTS (SELECT * FROM information_schema.COLUMNS B WHERE A.table_schema = B.table_schema AND A.table_name = B.table_name);
