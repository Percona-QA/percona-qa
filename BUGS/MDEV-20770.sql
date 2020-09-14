USE test;
CREATE TABLE t (a POLYGON NOT NULL, SPATIAL KEY i (a));
PREPARE s FROM "SHOW VARIABLES WHERE (1) IN (SELECT * FROM t)";
EXECUTE s;
EXECUTE s;

CREATE TABLE t1 (a GEOMETRY);
CREATE TABLE t2 (b INT);
# Data does not make any difference, it fails with empty tables too
INSERT INTO t1 VALUES (GeomFromText('POINT(0 0)')),(GeomFromText('POINT(1 1)'));
INSERT INTO t2 VALUES (1),(2);
PREPARE stmt FROM "SELECT * from t1 WHERE a IN (SELECT b FROM t2)";
EXECUTE stmt;
EXECUTE stmt;
