# mysqld options required for replay:  --sql_mode= 
SET @@SESSION.max_sort_length=4;
CREATE TABLE t (c TIMESTAMP(1));
INSERT INTO t VALUES(0);
DELETE FROM t ORDER BY c;
