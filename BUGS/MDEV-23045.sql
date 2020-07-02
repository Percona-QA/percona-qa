# mysqld options required for replay: --log-bin 
SET SQL_MODE='';
USE test;
RESET MASTER TO 5000000000;
CREATE TABLE t (c INT);
XA BEGIN 'a';
INSERT INTO t  VALUES ('a');
XA END 'a';
XA PREPARE 'a';
