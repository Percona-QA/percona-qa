# Repeat 3-10000000 times. Random delays may help. Highly sporadic.
# Single thread enough to reproduce, multi-threaded is likely faster.
DROP DATABASE test;CREATE DATABASE test;USE test;
CREATE TABLE t2 (a INT) ENGINE=InnoDB;
XA BEGIN 'x1';
SET GLOBAL innodb_lru_scan_depth=10000;
SET GLOBAL innodb_checksum_algorithm=3;
INSERT INTO t2 VALUES (1),(1),(1);
