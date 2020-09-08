SET NAMES latin1;
CREATE TABLE t1 (f VARCHAR(8) CHARACTER SET utf8, i INT);
INSERT INTO t1 VALUES ('foo',1),('bar',2);
SET in_predicate_conversion_threshold= 3;
PREPARE stmt FROM "SELECT * FROM t1 WHERE (f IN ('a','b','c') AND i = 10)";
EXECUTE stmt;
EXECUTE stmt;

SET SESSION in_predicate_conversion_threshold=1;
CREATE TABLE H (c VARCHAR(1) PRIMARY KEY);
PREPARE p FROM 'SELECT * FROM H WHERE c NOT IN (\'a\', \'a\')';
EXECUTE p;
EXECUTE p;
