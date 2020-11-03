# mysqld options required for replay: --log-bin 
USE test;
SET GLOBAL wsrep_forced_binlog_format=1;
CREATE TABLE t1(c INT PRIMARY KEY) ENGINE=MEMORY;
INSERT DELAYED INTO t1 VALUES(),(),();
SELECT SLEEP(1);

# mysqld options required for replay: --log-bin
SET SQL_MODE='';
SET GLOBAL wsrep_forced_binlog_format='STATEMENT';
HELP '%a';
CREATE TABLE t (c CHAR(8) NOT NULL) ENGINE=MEMORY;
SET max_session_mem_used = 50000;
REPLACE DELAYED t VALUES (5);
HELP 'a%';

# mysqld options required for replay: --log-bin 
SET SQL_MODE='';
CREATE TABLE t (c INT) ENGINE=MEMORY;
SET GLOBAL wsrep_forced_binlog_format='STATEMENT';
INSERT DELAYED INTO t VALUES(1);
SET GLOBAL wsrep_start_position='00000000-0000-0000-0000-000000000000:-2';
