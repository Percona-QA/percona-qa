#
# The purpose of this test is to exercise anything related to table locking:
#
# DDL, FLUSH, LOCK/UNLOCK, transactions
#
# 

query:
	ddl | dml | lock |
	ddl | dml | lock |
	ddl | dml | lock |
	ddl | dml | lock |
	ddl | dml | lock |
	ddl | dml | lock |
	ddl | dml | lock |
	flush | transaction;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK | SAVEPOINT A | ROLLBACK TO SAVEPOINT A ;

ddl:
	ALTER online ignore TABLE _table ENGINE = engine ;

dml:
	PREPARE st1 FROM " dml2 " ; EXECUTE st1 ; DEALLOCATE PREPARE st1 |
	dml2;

dml2:
	union | select | insert_replace | update | delete ;

union:
	select UNION select ;

select:
	SELECT high_priority sql_buffer_result sql_cache A . _field
	FROM _table AS A LEFT JOIN _table AS B USING (`pk`)
	LIMIT _digit
#	procedure
#	into
	for_update_lock_in_share_mode;

procedure:
	PROCEDURE ANALYSE(10, 2000);

into:
	INTO OUTFILE _tmpnam | 
	INTO DUMPFILE _tmpnam ;
#	INTO _letter ;

for_update_lock_in_share_mode:
	| FOR UPDATE | LOCK IN SHARE MODE ;

insert_replace:
	insert_replace2 low_priority_delayed_high_priority INTO _table ( _field ) select on_duplicate_key_update |
	insert_replace2 low_priority_delayed_high_priority INTO _table ( _field ) VALUES ( _digit ) on_duplicate_key_update ;

insert_replace2:
	INSERT | REPLACE ;

on_duplicate_key_update:
	| ON DUPLICATE KEY UPDATE _field = _digit ;

delete:
	DELETE low_priority quick ignore FROM _table WHERE `pk` > _digit LIMIT _digit |
	DELETE low_priority quick ignore A , B FROM _table AS A LEFT JOIN _table AS B USING (`pk`) LIMIT _digit ;

update:
	UPDATE low_priority ignore _table SET _field = _digit WHERE `pk` > _digit LIMIT _digit ;

quick:
	| QUICK ;

engine:
	MEMORY | MyISAM | InnoDB ;

online:
	ONLINE | ;

lock:
	LOCK TABLE lock_list |
	UNLOCK TABLES ;

flush:
	FLUSH TABLES WITH READ LOCK |
	FLUSH TABLE _table , _table ;

lock_list:
	lock_item |
	lock_item , lock_item ;

lock_item:
	_table lock_type ;

lock_type:
	READ local |
	low_priority WRITE ;

local:
	LOCAL | ;

low_priority:
	LOW_PRIORITY | ;

high_priority:
	HIGH_PRIORITY | ;

sql_buffer_result:
	SQL_BUFFER_RESULT | ;

sql_cache:
	SQL_CACHE | SQL_NO_CACHE | ;

low_priority_delayed_high_priority:
	LOW_PRIORITY | DELAYED | HIGH_PRIORITY ;

ignore:
	IGNORE | ;
