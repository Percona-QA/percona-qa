SET max_session_mem_used = 50000;
help 'it is going to crash';
help 'it is going to crash';
help 'it is going to crash';
help 'it is going to crash';
help 'it is going to crash';  # Crashes
help 'it crashed'; 

SET SQL_MODE='';
SET GLOBAL wsrep_forced_binlog_format='STATEMENT';
HELP '%a';
CREATE TABLE t (c CHAR(8) NOT NULL) ENGINE=MEMORY;
SET max_session_mem_used = 50000;
REPLACE DELAYED t VALUES (5);
HELP 'a%';
