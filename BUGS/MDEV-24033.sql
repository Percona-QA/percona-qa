SET sql_select_limit = 3;
CREATE TEMPORARY TABLE t (i INT);
INSERT INTO t VALUES (1), (2), (3), (4);
SET SESSION max_sort_length=4;
SELECT SUM(SUM(i)) OVER W FROM t GROUP BY i WINDOW w AS (PARTITION BY i ORDER BY i) ORDER BY SUM(SUM(i)) OVER w;

SET max_length_for_sort_data=30;
SET sql_select_limit = 3;
CREATE TABLE t1 (a DECIMAL(64,0), b INT);
INSERT INTO t1 VALUES (1,1), (2,2), (3,3), (4,4);
SET max_sort_length=8;
ANALYZE FORMAT=JSON SELECT * FROM t1 ORDER BY a+1;
SELECT * FROM t1 ORDER BY a+1;
