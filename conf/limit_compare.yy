query:
	select | select | select | select | select |
	dml | dml | dml | dml | dml |
	transaction |
	select | select | select | select | select |
	dml | dml | dml | dml | dml |
	transaction |
	select | select | select | select | select |
	dml | dml | dml | dml | dml |
	transaction |
	alter 
;

dml:
	update | insert | delete ;

select:
	SELECT * FROM _table where order_by limit;

where:
	|
	WHERE _field sign value |
	WHERE _field BETWEEN value AND value ;
#	WHERE _field IN ( value , value , value , value , value , value ) ;

sign:
	> | < | = | >= | <> | <= | != ;

order_by:
	ORDER BY _field , `pk` ;

limit:
	LIMIT _digit | LIMIT _tinyint_unsigned | LIMIT 65535 ;

insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table AS X SET _field = value where order_by limit;

delete:
	DELETE FROM _table where order_by LIMIT digit ;

transaction: START TRANSACTION | COMMIT | ROLLBACK ;

alter:
	ALTER ONLINE TABLE _table DROP KEY letter |
	ALTER ONLINE TABLE _table DROP KEY _field |
	ALTER ONLINE TABLE _table ADD KEY letter ( _field ) |
	ALTER ONLINE TABLE _table ADD KEY letter ( _field ) ;

value:
	_english | _digit | _date | _datetime | _time ;

# Use only indexed fields:

_field:
	`int_key` | `date_key` | `datetime_key` | `varchar_key` ;
