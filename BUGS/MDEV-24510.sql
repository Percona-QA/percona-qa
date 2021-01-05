SET SESSION sql_mode='NO_ZERO_DATE';
SET SESSION sql_buffer_result=ON;
SELECT CREATED INTO @c FROM information_schema.routines WHERE routine_schema='test' AND routine_name='a';

SET SESSION sql_buffer_result=1;
SET SQL_MODE='traditional';
SELECT event_name, created, last_altered FROM information_schema.events;
