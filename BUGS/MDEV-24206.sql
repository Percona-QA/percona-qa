DROP DATABASE test; 
CREATE DATABASE test; 
USE test; 
RENAME TABLE mysql.db TO mysql.db_bak;
CREATE TABLE mysql.db ENGINE=MEMORY SELECT * FROM mysql.db_bak;
GRANT SELECT ON mysql.* to 'a'@'a' IDENTIFIED BY 'a';
