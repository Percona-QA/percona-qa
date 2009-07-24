thread1_init:
	START TRANSACTION ;

thread1:
	SELECT * FROM _table |
	SELECT * FROM _table WHERE where_cond |
	SELECT SLEEP(60) ;

query:
	START TRANSACTION | COMMIT |
	update | update | update | update | update | update | update | update | update | update | update | update |
	update | update | update | update | update | update | update | update | update | update | update | update |
	update | update | update | update | update | update | update | update | update | update | update | update |
	update | update | update | update | update | update | update | update | update | update | update | update |
	update | update | update | update | update | update | update | update | update | update | update | update |
	update | update | update | update | update | update | update | update | update | update | update | update |
	update | update | update | update | update | update | update | update | update | update | update | update ;

update:
	UPDATE _table AS X SET _field = _char(255) WHERE where_cond;

where_cond:
	`pk` = _smallint_unsigned ;
