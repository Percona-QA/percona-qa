USE test;
CREATE FUNCTION f(c INT) RETURNS BLOB RETURN 0;
CREATE PROCEDURE p(IN c INT) SELECT f('a');
CALL p(0);
CALL p(0);