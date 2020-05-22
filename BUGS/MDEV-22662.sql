USE test;
SET @@in_predicate_conversion_threshold= 2;
CREATE TEMPORARY TABLE t(a INT);
SELECT HEX(a) FROM t WHERE a IN (CAST(0xffffffffffffffff AS INT),0);
