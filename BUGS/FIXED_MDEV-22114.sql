USE test;
CREATE TABLE t (a INT) ROW_FORMAT=COMPRESSED;
SET GLOBAL innodb_buffer_pool_evict='uncompressed';
