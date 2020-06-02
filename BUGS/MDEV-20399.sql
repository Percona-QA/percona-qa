SET GLOBAL innodb_encryption_threads=5;
SET GLOBAL innodb_encryption_rotate_key_age=0;
SELECT SLEEP(5);  # Somewhat delayed crash happens during sleep
