USE test;
CREATE TEMPORARY TABLE t(a INT,b INT);
SET SESSION in_predicate_conversion_threshold=2;
SELECT 1 FROM t WHERE ROW(a,(a,a)) IN ((1,(1,1)),(2,(2,1)));
