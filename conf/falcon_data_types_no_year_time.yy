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
	_english | _digit | NULL | _bigint_unsigned | _bigint | _date | _datetime | _timestamp | _char(64) | _mediumint ;


/* 2009-06-23: Removed fields 'year' and 'time' due to Bug#45499 (InnoDB inconsistency causing Falcon tests to fail) 
               Should re-configure pb2combinations.pl once this bug is fixed. */
