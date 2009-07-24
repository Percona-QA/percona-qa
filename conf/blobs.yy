
query:
	insert | update | select | delete | transaction ;

select:
	SELECT _data , _field FROM _table ORDER BY RAND() LIMIT 1;

insert:
	INSERT INTO _table ( _field ) VALUES ( _data ) ;

update:
	UPDATE _table SET _field = _data ORDER BY RAND() LIMIT 1 ;

delete:
	DELETE FROM _table WHERE _field = _data ORDER BY RAND () LIMIT 1 ;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK ;
