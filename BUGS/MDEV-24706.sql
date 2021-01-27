CREATE OR REPLACE TABLE mysql.slow_log (a INT);
CREATE EVENT one_event ON SCHEDULE EVERY 10 SECOND DO SELECT 123;
SET GLOBAL slow_query_log=ON;
SET GLOBAL event_scheduler= 1;
SET GLOBAL log_output=',TABLE';
SET GLOBAL long_query_time=0.001;
SELECT SLEEP (3);

CREATE OR REPLACE TABLE mysql.slow_log (a INT);
DROP EVENT one_event;
CREATE EVENT one_event ON SCHEDULE EVERY 10 SECOND DO SELECT 123;
SET GLOBAL slow_query_log=ON;
SET GLOBAL event_scheduler= 1;
SET GLOBAL log_output=',TABLE';
SET GLOBAL long_query_time=0.001;
SELECT SLEEP (3);
