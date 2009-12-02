thread1:
	dml ; SELECT SLEEP (10) ;

query:
	select | select | select | select | select |
	select | select | select | select | select |
	select | select | select | select | select |
	dml | dml | dml | dml | dml |
	transaction ;
dml:
	update | insert | delete ;

select:
	SELECT select_item FROM join where order_by limit;

select_item:
	* | X . _field ;

join:
	_table AS X | 
	_big_table AS X LEFT JOIN _small_table AS Y USING ( _field ) ;

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
	ORDER BY X . _field ;

delete_order_by:
	ORDER BY _field ;

limit:
	LIMIT digit ;
	
insert:
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) ;

update:
	UPDATE _table AS X SET _field = value where order_by limit ;

delete:
	DELETE FROM _table where_delete delete_order_by LIMIT digit ;

transaction: START TRANSACTION | COMMIT | ROLLBACK ;

alter:
	ALTER TABLE _table DROP KEY letter |
	ALTER TABLE _table DROP KEY _field |
	ALTER TABLE _table ADD KEY letter ( _field ) ;

value:
	' letter ' | digit | _date | _datetime | _time ;

# Use only medimum - sized tables for this test

_table:
	C | D | E ;

_big_table:
	C | D | E ;

_small_table:
	A | B | C ;

# Use only indexed fields:

_field:
	`col_int_key` | `col_date_key` | `col_datetime_key` | `col_varchar_key` ;

