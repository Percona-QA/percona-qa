# mysqld options required for replay: --log-bin 
USE test;
SET GLOBAL wsrep_forced_binlog_format=1;
CREATE TABLE t1(c INT PRIMARY KEY) ENGINE=MEMORY;
INSERT DELAYED INTO t1 VALUES(),(),();
SELECT SLEEP(1);
