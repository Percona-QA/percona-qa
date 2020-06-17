# Keep testcase repeating until mysqld crashes (one time often if not always enough on debug, optimized may take 2-x attempts)
USE test;
SET SQL_MODE='';
SET SESSION enforce_storage_engine=MEMORY;
SET SESSION optimizer_trace='enabled=on';
CREATE TABLE t1( a INT, b INT, KEY( a ) ) ;
SELECT MAX(a), SUM(MAX(a)) OVER () FROM t1 WHERE a > 10;
SELECT * FROM information_schema.session_variables WHERE variable_name='innodb_ft_min_token_size';
UPDATE t1 SET b=REPEAT(LEFT(b,1),200) WHERE a=1;

USE test;
SET SQL_MODE='';
SET SESSION enforce_storage_engine=MEMORY ;
SET SESSION optimizer_trace='enabled=on';
CREATE TABLE t(a INT, b INT, KEY(a)) ;
SELECT MAX(a), SUM(MAX(a)) OVER () FROM t WHERE a>10;
SELECT * FROM information_schema.session_variables WHERE variable_name='innodb_ft_min_token_size';
UPDATE t SET b=repeat(left(b,1),200) WHERE a=1;

# mysqld options required for replay:  --sql_mode= 
USE test;
SET SESSION enforce_storage_engine=MEMORY;
SET @@SESSION.optimizer_trace='enabled=on';
CREATE TABLE t1( a INT, b INT, KEY( a ) ) ;
select max(a), sum(max(a)) over () FROM t1  where a > 10;
select * from information_schema.session_variables where variable_name='innodb_ft_min_token_size';
update t1 set b=repeat(left(b,1),200) where a=1; ;
