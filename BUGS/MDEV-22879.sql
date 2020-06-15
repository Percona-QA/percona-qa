SET SQL_MODE='';
USE test;
SET STATEMENT max_statement_time=20 FOR BACKUP LOCK test.t1;
CREATE TABLE IF NOT EXISTS t3 (c1 CHAR(1) BINARY,c2 SMALLINT(10),c3 NUMERIC(1,0), PRIMARY KEY(c1(1))) ENGINE=InnoDB;
LOCK TABLES t3 AS a2 WRITE, t3 AS a1 READ LOCAL;
UNLOCK TABLES;
DROP TABLE t1,t2,t0;
# Shutdown (using mysqladmin shutdown), observe crash (or hang) during shutdown

USE test;
SET SQL_MODE='';
SET STATEMENT max_statement_time=180 FOR BACKUP LOCK test.t;
CREATE TABLE t (c1 INT PRIMARY KEY) ENGINE=Aria;
LOCK TABLES t AS a2 WRITE, t AS a1 READ LOCAL;
UNLOCK TABLES;
DROP TABLE t1,t2,t0;
# Shutdown (using mysqladmin shutdown), observe crash (or hang) during shutdown
