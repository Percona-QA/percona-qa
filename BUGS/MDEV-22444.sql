USE test;
SET @@SESSION.optimizer_trace=1;
SET in_predicate_conversion_threshold=2;
CREATE TABLE t1(c1 YEAR);
SELECT * FROM t1 WHERE c1 IN(NOW(),NOW());
