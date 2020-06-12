USE test;
SET collation_connection='utf16_general_ci';
SET sql_buffer_result=1;
CREATE TABLE t(c INT);
INSERT INTO t VALUES(NULL);
SELECT PASSWORD(c) FROM t;
