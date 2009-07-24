query:
	select | dml | dml | 
	select | dml | dml | 
	select | dml | dml | 
	select | dml | dml | 
	select | dml | dml | transaction ;
dml:
	update | insert | insert | insert | delete ;

select:
	SELECT _field FROM _table where order_by limit;

where:
	|
	WHERE _field < value |
	WHERE _field > value |
	WHERE _field = value ;

order_by:
	| 
	ORDER BY _field ;

limit:
	|
	LIMIT digit ;
	
insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table SET _field = value where order_by limit ;

delete:
	DELETE FROM _table where LIMIT digit ;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK ;

value:
	REPEAT( value_one , tinyint_unsigned ) ;

value_one:
	' letter ' | digit | _date | _datetime | _time ;
