USE test;
SET @@tmp_disk_table_size=1024;
CREATE VIEW v AS SELECT 'a';
SELECT table_name FROM INFORMATION_SCHEMA.views;
