SET @@SESSION.tmp_table_size=1048576;
SET @@SESSION.max_sort_length=5;
SET @@SESSION.sort_buffer_size=1024;
SET @@SESSION.max_length_for_sort_data=66556;
SELECT * FROM information_schema.session_variables ORDER BY variable_name;

USE test;
SET SQL_MODE='';
CREATE TABLE t (c1 TIME PRIMARY KEY,c2 TIMESTAMP(3),c3 VARCHAR(1025) CHARACTER SET 'utf8' COLLATE 'utf8_bin') ;
INSERT INTO t VALUES (SYSDATE(2),'',GET_FORMAT(DATETIME,'ISO'));
SET SESSION max_length_for_sort_data=8388608;
SET SESSION sort_buffer_size=16;
SELECT * FROM t WHERE c1 BETWEEN '00:00:00' AND '23:59:59' ORDER BY c1,c2;
