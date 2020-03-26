SET @@SESSION.max_sort_length=2000000;
USE INFORMATION_SCHEMA;
SELECT * FROM tables t JOIN columns c ON t.table_schema=c.table_schema WHERE c.table_schema=(SELECT COUNT(*) FROM INFORMATION_SCHEMA.columns GROUP BY column_type) GROUP BY t.table_name;
