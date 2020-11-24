SET SQL_MODE='';
SET SESSION optimizer_switch="not_null_range_scan=ON";
CREATE TEMPORARY TABLE t (a INT, b INT, PRIMARY KEY(a), INDEX (b)) ENGINE=MyISAM;
INSERT INTO t (a,b) VALUES (0,0),(1,1),(2,'a');
SET @a=0.0;
SELECT a,b FROM t AS d WHERE a=(SELECT a FROM t WHERE b=@a) AND b='a';
