SET GLOBAL innodb_adaptive_flushing_lwm=0.0;
CREATE TABLE t (c DOUBLE) ENGINE=InnoDB;
SET GLOBAL innodb_io_capacity=18446744073709551615;
SELECT SLEEP (3);

SET GLOBAL innodb_adaptive_flushing_lwm=0.0;
SET GLOBAL innodb_max_dirty_pages_pct_lwm=0.000001;
CREATE TABLE t (c DOUBLE) ENGINE=InnoDB;
SET GLOBAL innodb_io_capacity=18446744073709551615;
SHOW WARNINGS;
SELECT @@innodb_io_capacity;
SELECT @@innodb_io_capacity_max;
SELECT SLEEP (3);
