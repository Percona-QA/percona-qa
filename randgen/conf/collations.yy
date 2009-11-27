query:
	delete | insert | update ;

xid_event:
	START TRANSACTION | COMMIT ;
insert:
	INSERT INTO table_name ( field_name ) VALUES ( _charset ' letter ' ) ;

update:
	UPDATE table_name SET field_name = _charset ' letter ' WHERE field_name oper _charset ' letter ';

delete:
	DELETE FROM table_name WHERE field_name oper _charset ' letter ';

table_name:
	_table ;

field_name:
	`col_varchar_key` | `col_varchar_nokey` ;

oper:
	= | > | < | >= | <= | <> ;
