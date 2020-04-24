SET @stats.save= @@innodb_stats_persistent;
SET GLOBAL innodb_stats_persistent= ON;
CREATE TABLE t1 (a CHAR(100), pk INTEGER AUTO_INCREMENT, b BIT(8), c CHAR(115) AS (a) VIRTUAL, PRIMARY KEY(pk), KEY(c), KEY(b)) ENGINE=InnoDB;
INSERT INTO t1 (a,b) VALUES ('foo',b'0'),('',NULL),(NULL,b'1');
CREATE TABLE t2 (f CHAR(100)) ENGINE=InnoDB;
SELECT t1a.* FROM t1 AS t1a JOIN t1 AS t1b LEFT JOIN t2  ON (f = t1b.a) WHERE t1a.b >= 0 AND t1a.c = t1b.a;
