USE test;
CREATE TABLE t (c int) ENGINE=InnoDB key_block_size= 4;
SET GLOBAL innodb_buffer_pool_evict='uncompressed';
SET GLOBAL innodb_checksum_algorithm=strict_none;
SELECT SLEEP(10);  # Server crashes during sleep

USE test;
CREATE TABLE t(a INT) ENGINE=InnoDB ROW_FORMAT=COMPRESSED KEY_BLOCK_SIZE=1;
SET GLOBAL innodb_buffer_pool_evict='uncompressed';
SET GLOBAL innodb_checksum_algorithm=3;
SELECT SLEEP(5);  # Server crashes during sleep
