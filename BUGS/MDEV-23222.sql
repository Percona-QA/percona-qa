USE test;
CREATE TABLE t1 (a INT);
INSERT INTO t1 VALUES (1);
CREATE TABLE t2 (i INT) DATA DIRECTORY = '/tmp', ENGINE=Aria;
CREATE TABLE t2 (i INT) DATA DIRECTORY = '/tmp', ENGINE=Aria;

# Repeat as needed, also attempt replay via pquery
# mysqld options required for replay:  --sql_mode=
DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE TABLE   t1   (a TINYINT UNSIGNED, b SMALLINT UNSIGNED, c CHAR(61) NOT NULL, d VARBINARY(78), e VARCHAR(72), f VARCHAR(43) NOT NULL, g MEDIUMBLOB NOT NULL, h LONGBLOB NOT NULL, id BIGINT NOT NULL, KEY(b), KEY(e), PRIMARY KEY(id)) ;
set session default_storage_engine=Aria;
CREATE TABLE t(i int) DATA DIRECTORY = '/tmp', ENGINE = RocksDB;
create table tm (k int, index (k)) charset utf8mb4 ;
INSERT INTO   t1   VALUES (2890623675590946934,11482198,'Lo6MOErYmXjTta3P5lTt78F9Yv1BbFNxFma2','OnWYE1g7gL2DIQuFMmIRFJ3ZbDXB6sO3AOPx06mc0y7RDQNU2DSKisEuar8GQqb5dvQTr5JJLerMYKff9OeZc3jygymh0PDexjenuUVNtUVccrHnVCUwaOmYL','M82','R','h','v',12); ;
