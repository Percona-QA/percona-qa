CREATE DATABASE `db_new..............................................end`;
SET SESSION foreign_key_checks=0;
USE `db_new..............................................end`;
CREATE TABLE mytable_ref (id int,constraint FOREIGN KEY (id) REFERENCES FOO(id) ON DELETE CASCADE) ;
SELECT constraint_catalog, constraint_schema, constraint_name, table_catalog, table_schema, table_name, column_name FROM information_schema.key_column_usage WHERE (constraint_catalog IS NOT NULL OR table_catalog IS NOT NULL) AND table_name != 'abcdefghijklmnopqrstuvwxyz' ORDER BY constraint_name, table_name, column_name;
