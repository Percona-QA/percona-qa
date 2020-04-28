DROP TABLE mysql.general_log;
CREATE TABLE mysql.general_log(a int);
SET GLOBAL general_log='ON';
SET GLOBAL log_output='TABLE';
SELECT 1;
