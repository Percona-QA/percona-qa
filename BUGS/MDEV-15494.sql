USE test;
SET @@global.log_bin_trust_function_creators=1;
CREATE TABLE t(pk TIMESTAMP DEFAULT '0000-00-00 00:00:00.00',b DATE,KEY (pk));
CREATE FUNCTION f() RETURNS INT RETURN (SELECT notthere FROM t LIMIT 1);
XA BEGIN 'a';
SELECT f(@b,'a');
XA END 'a';
XA PREPARE 'a';
SELECT f(@a,@b);
