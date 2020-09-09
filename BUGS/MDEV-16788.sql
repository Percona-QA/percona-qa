SET collation_connection=ucs2_general_ci;
INSERT INTO mysql.proc (db, name, type, specific_name, language, sql_data_access, is_deterministic, security_type, param_list, returns, body, definer, created, modified, sql_mode, comment, character_set_client, collation_connection, db_collation, body_utf8 ) VALUES ( 'a', 'a', 'FUNCTION', 'bug14233_1', 'SQL', 'READS_SQL_DATA', 'NO', 'DEFINER', '', 'int(10)', 'SELECT * FROM mysql.user', 'root@localhost', NOW(), '0000-00-00 00:00:00', '', '', '', '', '', 'SELECT * FROM mysql.user' );
SELECT * FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_NAME='a';

SET CHARACTER_SET_CONNECTION=ucs2;
INSERT INTO mysql.proc (db, name, type, specific_name, language, sql_data_access, is_deterministic, security_type, param_list, returns, body, definer, created, modified, sql_mode, comment, character_set_client, collation_connection, db_collation, body_utf8 ) VALUES ('test','bug14233_1','FUNCTION','bug14233_1','SQL','READS_SQL_DATA','NO','DEFINER','','int(10)','SELECT COUNT(*) FROM mysql.user','root@localhost', NOW() , '0000-00-00 00:00:00','','','','','','SELECT COUNT(*) FROM mysql.user');
SHOW FUNCTION STATUS WHERE db=DATABASE();

CREATE TABLE t1 (k INT);
CREATE PROCEDURE pr() ALTER TABLE t1 ADD CONSTRAINT CHECK (k != 5);
CALL pr;
CALL pr;
