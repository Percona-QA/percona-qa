CREATE DATABASE IF NOT EXISTS load_data_infile_test;
USE load_data_infile_test;

DROP TABLE IF EXISTS t1_@@SE@@;
CREATE TABLE t1_@@SE@@ (
	a1 INT,
	a2 DECIMAL(65,10),
	a3 CHAR(255) COLLATE 'latin1_bin',
	a4 TIMESTAMP,
	a5 TEXT CHARACTER SET 'utf8' COLLATE 'utf8_bin',
	PRIMARY KEY (a1) COMMENT 'cf_t1'
) ENGINE=@@SE@@ PARTITION BY HASH(a1) PARTITIONS 4;

DROP TABLE IF EXISTS t2_@@SE@@;
CREATE TABLE t2_@@SE@@ (
	a1 DATE,
	a2 TIME,
	a3 BLOB,
	a4 varchar(100) COLLATE 'latin1_bin',
	a5 float(25,5),
	PRIMARY KEY (a1) COMMENT 'cf_t2'
) ENGINE=@@SE@@;

DROP TABLE IF EXISTS t3_@@SE@@;
CREATE TABLE t3_@@SE@@ (
	a1 varchar(255) COLLATE 'binary',
	a2 BINARY(20),
	a3 VARBINARY(100),
	a4 SET('one', 'two', 'three'),
	a5 ENUM('x-small', 'small', 'medium', 'large', 'x-large'),
	PRIMARY KEY (a1) COMMENT 'cf_t3'
) ENGINE=@@SE@@;
