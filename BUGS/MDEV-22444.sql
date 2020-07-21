USE test;
SET @@SESSION.optimizer_trace=1;
SET in_predicate_conversion_threshold=2;
CREATE TABLE t1(c1 YEAR);
SELECT * FROM t1 WHERE c1 IN(NOW(),NOW());

SET in_predicate_conversion_threshold=2;
CREATE TABLE t1(c1 YEAR);
SELECT * FROM t1 WHERE c1 IN(NOW(),NOW());
drop table t1;

USE test;
SET IN_PREDICATE_CONVERSION_THRESHOLD=2;
CREATE TABLE t(c BIGINT NOT NULL);
SELECT * FROM t WHERE c IN (CURDATE(),ADDDATE(CURDATE(),'a')) ORDER BY c;
