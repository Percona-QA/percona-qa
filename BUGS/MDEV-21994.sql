BACKUP LOCK x;
RESET QUERY CACHE;

SET STATEMENT max_statement_time=180 FOR BACKUP LOCK t;
RESET SLAVE ALL;