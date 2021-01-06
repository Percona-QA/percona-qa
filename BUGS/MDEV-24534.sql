# mysqld options required for replay: --log-bin 
SET GLOBAL autocommit=0;
SET GLOBAL event_scheduler= ON;
SET timestamp=12345;
CREATE TABLE t1 (c1 INT ZEROFILL NULL);
CREATE EVENT e1 ON SCHEDULE AT current_timestamp + INTERVAL 1 DAY DO INSERT INTO t1 VALUES (1);
SELECT SLEEP (3);
