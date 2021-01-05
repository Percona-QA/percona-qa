# Repeat 1-10 times
SET GLOBAL innodb_limit_optimistic_insert_debug=2;
CREATE TABLE t (p1 POINT NOT NULL, p2 POINT NOT NULL, SPATIAL KEY k1 (p1), SPATIAL KEY k2 (p2)) ;
XA START 'x';
INSERT INTO t VALUES (ST_PointFromText('POINT(1.1 1.1)'), ST_PointFromText('POINT(1.1 1.1)')), (ST_PointFromText('POINT(1.1 1.1)'), ST_PointFromText('POINT(1.1 1.1)')), (ST_PointFromText('POINT(1.1 1.1)'), ST_PointFromText('POINT(1.1 1.1)')), (ST_PointFromText('POINT(1.1 1.1)'), ST_PointFromText('POINT(1.1 1.1)'));
XA END 'x';
LOAD INDEX INTO CACHE t1 IGNORE LEAVES;


