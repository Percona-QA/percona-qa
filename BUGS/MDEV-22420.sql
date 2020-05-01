# mysqld options required for replay: --log-bin 
USE test;
XA START '0';
CREATE TEMPORARY TABLE t(c INT);
XA END '0';
XA PREPARE '0';
DROP TEMPORARY TABLE t;
# shutdown of sever, or some delay, may be required before crash happens
