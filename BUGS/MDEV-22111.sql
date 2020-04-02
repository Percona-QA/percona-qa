USE test;
SET @@SESSION.COLLATION_CONNECTION=utf16_hungarian_ci;
CREATE TABLE t(c ENUM('aaaaaaaa') CHARACTER SET 'Binary',d JSON);
CREATE TABLE t1(c ENUM('aaaaaaaaa') CHARACTER SET 'Binary',d JSON);
CREATE TABLE t2(c ENUM('aaaaaaaaaa') CHARACTER SET 'Binary',d JSON);
