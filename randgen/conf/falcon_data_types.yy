query:
	transaction | select |
	dml | dml | dml | dml | dml ;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK ;

select:
	SELECT select_item FROM _table WHERE _field sign value ;

select_item:
	_field |
	_field null |
	_field op _field |
	_field sign _field ;

null:
	IS NULL | IS NOT NULL ;

op:
	+ | - | * | / | DIV ;

dml:
	insert | update | delete ;

insert:
	INSERT IGNORE INTO _table ( _field , _field , _field ) VALUES ( value , value , value );

update:
	UPDATE _table SET _field = value WHERE _field sign value ;

delete:
	DELETE FROM _table WHERE `pk` = value ;

sign:
	< | > | = | >= | <= | <> | != ;

value:
	_english | _digit | NULL | _bigint_unsigned | _bigint | _date | _time | _datetime | _timestamp | _year | _char(64) | _mediumint ;
