USE test;
SET SESSION innodb_compression_default=1;
SET GLOBAL innodb_compression_level=0;
CREATE TABLE t(c INT);
