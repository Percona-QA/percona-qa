# Causes hangs on 10.5.4 shutdown
USE test;
CREATE TABLE t(a INT);
XA START '0';
SET pseudo_slave_mode=1;
INSERT INTO t VALUES(7050+0.75);
XA PREPARE '0';
XA END '0';
XA PREPARE '0';
TRUNCATE TABLE t;
# Shutdown to observe hang (mysqladmin shutdown will hang)
