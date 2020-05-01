# mysqld options required for replay:  --sql_mode= 
SET @@SESSION.max_sort_length=4;
CREATE TABLE t (c TIMESTAMP(1));
INSERT INTO t VALUES(0);
DELETE FROM t ORDER BY c;

# mysqld options required for replay:  --sql_mode=
USE test;
SET @@SESSION.max_sort_length=1;
CREATE TEMPORARY TABLE t(c DATETIME);
INSERT INTO t VALUES(0);
DELETE FROM t ORDER BY c;

# mysqld options required for replay:  --sql_mode=
USE test;
SET @@SESSION.max_sort_length=4;
CREATE TEMPORARY TABLE t1(c INET6,d DATE);
INSERT INTO t1 VALUES(0,0);
SELECT c FROM t1 ORDER BY c;
