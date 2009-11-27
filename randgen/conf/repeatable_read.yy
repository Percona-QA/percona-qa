query_init:
	SET GLOBAL TRANSACTION ISOLATION LEVEL REPEATABLE READ ; SET AUTOCOMMIT=OFF ;

query:
	transaction | insert | update | delete | select ;
transaction:
	START TRANSACTION | COMMIT | ROLLBACK | SAVEPOINT A | ROLLBACK TO SAVEPOINT A ;

update:
 	UPDATE _table SET _field = _digit WHERE condition LIMIT _digit ;

delete:
	DELETE FROM _table WHERE condition LIMIT _digit ;

insert:
	INSERT INTO _table ( `col_int_key`, `col_int` ) VALUES ( _digit , _digit ) ;

condition:
	1 = 1 |
	_field < _digit |
	_field = _digit |
	_field > _digit |
	_field BETWEEN _digit and _digit |
	_field IN ( _digit , _digit , _digit );

select:
	SELECT _field FROM _table WHERE condition ;
