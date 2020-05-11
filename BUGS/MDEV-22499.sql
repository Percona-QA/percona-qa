USE test;
SET @@SESSION.collation_connection=utf32_estonian_ci;
CREATE TABLE t1(c1 SET('a') COLLATE 'Binary',c2 JSON);
