# mysqld options required for replay:  --sql_mode=
USE test;
CREATE TABLE t (c INT) ENGINE=Aria;
INSERT INTO t VALUES (0);
REPAIR TABLE t QUICK USE_FRM ;
INSERT INTO t SELECT * FROM t;
