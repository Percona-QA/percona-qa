query:
	select | insert | update | delete | transaction ;

select:
	SELECT select_item FROM join where order_by limit;

select_item:
	* | X . _field | COUNT( X . _field ) | COUNT( * ) ;

join:
	_table AS X | 
	_table AS X LEFT JOIN _table AS Y ON ( X . _field = Y . _field ) ;

_table:
	A | B | C | D ;	# Avoid using overly large tables, such as table E

where:
	|
	WHERE X . _field < value |
	WHERE X . _field > value |
	WHERE X . _field = value ;

where_delete:
	|
	WHERE _field < value |
	WHERE _field > value |
	WHERE _field = value ;

order_by:
	| ORDER BY X . _field ;

limit:
	| LIMIT digit ;
	
insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table AS X SET _field = value where order_by limit ;

delete:
	DELETE FROM _table where_delete LIMIT digit ;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK ;

value:
	' letter ' | digit | _date | _datetime | _time ;
