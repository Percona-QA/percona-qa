SET GLOBAL aria_encrypt_tables= 1;
CREATE TABLE t1 (pk INT PRIMARY KEY, a INT, KEY(a)) ENGINE=Aria TRANSACTIONAL=1;
ALTER TABLE t1 DISABLE KEYS;
INSERT INTO t1 VALUES  (1,1);
ALTER TABLE t1 ENABLE KEYS;

USE test;
CREATE TABLE t(c1 INT,KEY(c1))ENGINE=InnoDB;
INSERT INTO t VALUES(55997),(3942);
ALTER TABLE t ENGINE=Aria;
SET GLOBAL aria_encrypt_tables=1;
REPAIR TABLE t USE_FRM;
REPAIR TABLE t USE_FRM;

USE test;
SET GLOBAL aria_encrypt_tables=1;
CREATE TABLE t1(id int,key GEN_CLUST_INDEX(id))engine=Aria;
INSERT INTO t1 SELECT timediff(timestamp'2008-12-31 23:59:59.000001',timestamp'2008-12-30 01:01:01.000002');
# Then shutdown server

USE test;
SET GLOBAL table_open_cache=FALSE;
SET default_storage_engine=Aria;
SET GLOBAL aria_encrypt_tables=ON;
CREATE TABLE t(GRADE DECIMAL PRIMARY KEY);
INSERT INTO t VALUES(0);
CREATE TEMPORARY TABLE t SELECT 1 f1;
CREATE USER a@localhost IDENTIFIED WITH '';
DROP TABLE t,t2;
ANALYZE NO_WRITE_TO_BINLOG TABLE t;

USE test;
SET SQL_MODE='';
CREATE TABLE t2(a INT KEY) ROW_FORMAT=REDUNDANT;
SET GLOBAL aria_encrypt_tables=ON;
CREATE TABLE t1(c1 DECIMAL KEY,c2 DECIMAL) ENGINE=Aria;
INSERT INTO t1 VALUES(0,x'');
DROP TABLES t1,t2;

USE test;
SET SQL_MODE='';
SET GLOBAL aria_encrypt_tables=1;
CREATE TABLE t1 (c1 INT PRIMARY KEY) ENGINE=Aria;
INSERT INTO t1 VALUES (1);
CREATE TRIGGER t1_ai AFTER INSERT ON t1 FOR EACH ROW SET @a:='a';

USE test;
SET SQL_MODE='';
SET @@global.table_open_cache = 0;
CREATE TABLE ti (a SMALLINT UNSIGNED, b SMALLINT NOT NULL, c BINARY(15), d VARBINARY(5), e VARCHAR(3), f VARCHAR(42), g MEDIUMBLOB NOT NULL, h MEDIUMBLOB, id BIGINT NOT NULL, KEY(b), KEY(e), PRIMARY KEY(id));
CREATE PROCEDURE p2 (OUT i1 VARCHAR(2037) BINARY CHARACTER SET 'Binary' COLLATE 'Binary') CONTAINS SQL SET @@GLOBAL.OPTIMIZER_SWITCH="loosescan=OFF";
set global aria_encrypt_tables=ON;
INSERT INTO ti VALUES (0,0,'a','a','a','a','a','D',6);
CREATE TABLE t(a TINYINT NOT NULL,b TINYINT,PRIMARY KEY(b)) ENGINE=Aria;
INSERT INTO t VALUES (1,1),(2,2),(3,3),(4,4),(5,5),(6,6),(7,7),(8,8),(9,9),(10,10);
CREATE TABLE t3 (a CHAR(2), KEY (a)) ENGINE = MEMORY;
ALTER TABLE t3 ADD INDEX (c1);
INSERT INTO ti VALUES (0,0,'a','a','a','a','a','a',3);
DROP PROCEDURE IF EXISTS p2;

USE test;
SET GLOBAL aria_encrypt_tables=1;
CREATE TABLE t (a INT AUTO_INCREMENT PRIMARY KEY, b INT) ENGINE=Aria;
INSERT INTO t VALUES (6,2);
ANALYZE NO_WRITE_TO_BINLOG TABLE t;

USE test;
SET SQL_MODE='';
set global aria_encrypt_tables=1;
SET @@session.enforce_storage_engine = Aria;
CREATE TABLE ti (a TINYINT, b TINYINT, c CHAR(79), d VARCHAR(63), e VARCHAR(24) NOT NULL, f VARBINARY(8) NOT NULL, g BLOB, h MEDIUMBLOB NOT NULL, id BIGINT NOT NULL, KEY(b), KEY(e), PRIMARY KEY(id)) ;
create temporary table t1(a int not null primary key, b int, key(b)) ;
INSERT INTO t1 VALUES(0, 0);
DELETE FROM t1  WHERE a BETWEEN 0 AND 20 OR b BETWEEN 10 AND 20;
INSERT INTO t1 SELECT a, b+8192    FROM t1;
INSERT INTO ti VALUES (3290419791330308384,3170882006491468321,'abcdefghijklmnopqrstuvwxyz','abcdefghijklmnopqrstuvwxyz','abcdefghijklmnopqrstuvwxyz','abcdefghijklmnopqrstuvwxyz','abcdefghijklmnopqrstuvwxyz','abcdefghijklmnopqrstuvwxyz',2);
INSERT INTO t1 VALUES(4, 'abcdefghijklmnopqrstuvwxyz'); ;
INSERT INTO t1 VALUES(4, 'abcdefghijklmnopqrstuvwxyz'); ;

USE test;
SET SQL_MODE='';
SET GLOBAL aria_encrypt_tables=1;
CREATE TABLE t1 (c1 INT PRIMARY KEY) ENGINE=Aria;
INSERT INTO t1 VALUES (1);
CREATE TRIGGER t1_ai AFTER INSERT ON t1 FOR EACH ROW SET @a:='a';

USE test;
SET SQL_MODE='';
CREATE TABLE t (a INT PRIMARY KEY, b INT, KEY b_idx(b)) ;
INSERT INTO t VALUES(1, 'abcdefghijklmnopqrstuvwxyz');
SET SESSION enforce_storage_engine=Aria;
SELECT * FROM t INTO OUTFILE 'abcdefghijklmnopqrstuvwxyz';
set global aria_encrypt_tables=ON;
CREATE TEMPORARY TABLE t (c1 INT, INDEX(c1)) UNION=(t1,t2);
LOAD DATA INFILE 'abcdefghijklmnopqrstuvwxyz' INTO TABLE t;
