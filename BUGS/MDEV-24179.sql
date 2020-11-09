DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE VIEW v AS SELECT table_schema  AS object_schema, table_name  AS object_name, table_type AS object_type FROM information_schema.tables ORDER BY object_schema;
SELECT * FROM v LIMIT ROWS EXAMINED 9;
