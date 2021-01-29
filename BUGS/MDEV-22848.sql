# mysqld options required for replay: --log-bin
USE test;
SET autocommit=0;
CREATE TABLE t1 (c INT) ENGINE=MyISAM;
SET GLOBAL gtid_slave_pos="0-1-100";
INSERT INTO t1 VALUES (0);
DROP TABLE not_there;

SET autocommit=0;
SET GLOBAL gtid_slave_pos= "0-1-50";
SAVEPOINT a;
