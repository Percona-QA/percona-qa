SET @@session.slow_query_log = ON;
alter table mysql.slow_log engine=Aria;
SET @@global.slow_query_log = 1;
SET @@session.long_query_time = 0;
SET @@global.log_output = 'TABLE,,FILE,,,';
SELECT SLEEP(5);
