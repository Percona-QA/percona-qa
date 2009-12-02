query:
	select | select | select | select | select |
	select | select | select | select | select |
	select | select | select | select | select |
	dml | dml | dml | dml | dml |
	transaction |
	alter ;

dml:
	update | insert | delete ;

select:
	SELECT * FROM _table where;

where:
	|
	WHERE _field sign value |
	WHERE _field BETWEEN value AND value |
	WHERE _field IN ( value , value , value , value , value , value ) ;

sign:
	> | < | = | >= | <> | <= | != ;

insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table AS X SET _field = value where ;

delete:
	DELETE FROM _table where ORDER BY `pk` LIMIT digit ;

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
	`col_int_key` | `col_date_key` | `col_datetime_key` | `col_varchar_key` ;
