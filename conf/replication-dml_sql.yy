query:
	binlog_event ;
	# binlog_event | binlog_event | binlog_event | binlog_event | binlog_event |
	# binlog_event | binlog_event | binlog_event | binlog_event | binlog_event |
	# binlog_event | binlog_event | binlog_event | binlog_event | binlog_event | ddl ;

query_init:
	# 1. Bernt says an early metadata query helps to avoid the RQG RC = 255 problem.
	# 2. For debugging the grammar :   $safety_check = "/* QUERY_IS_REPLICATION_SAFE */"
	#    For faster execution      :   $safety_check = ""
	SELECT ' _table ', ' _field ' ; { $safety_check = "/* QUERY_IS_REPLICATION_SAFE */" ; return undef } ;

engine_type:
	MyISAM | InnoDB ;

binlog_event:
	single_dml_event   |
	single_dml_event   |
   sequence_dml_event |
	# xid_event |
	# query_event |
	# intvar_event |
	# rand_event |
	# user_var_event |
	rotate_event       ;

rotate_event:
	FLUSH LOGS ;
	
query_event:
	binlog_format_statement ; { return $safety_check } dml ; { return $safety_check } dml ; { return $safety_check } dml ; { return $safety_check } dml ; binlog_format_restore ;

intvar_event:
	intvar_event_pk | intvar_event_last_insert_id ;

intvar_event_pk:
	binlog_format_statement ;  { return $safety_check } INSERT INTO _table ( `pk` ) VALUES ( NULL ) ; binlog_format_restore ;

intvar_event_last_insert_id:
	binlog_format_statement ;  { return $safety_check } INSERT INTO _table ( _field ) VALUES ( LAST_INSERT_ID() ) ; binlog_format_restore ;

rand_event:
	binlog_format_statement ; rand_event_dml ; binlog_format_restore ;

rand_event_dml:
	 { return $safety_check } INSERT INTO _table ( _field ) VALUES ( RAND () ) |
	 { return $safety_check } UPDATE _table SET _field = RAND() where ORDER BY RAND () limit |
	 { return $safety_check } DELETE FROM _table WHERE _field < RAND() limit ;

user_var_event:
	binlog_format_statement ; SET @a = value ; user_var_dml ; binlog_format_restore ;

user_var_dml:
	 { return $safety_check } INSERT INTO _table ( _field ) VALUES ( @a ) |
	 { return $safety_check } UPDATE _table SET _field = @a ORDER BY _field LIMIT digit |
	 { return $safety_check } DELETE FROM _table WHERE _field < @a LIMIT 1 ;

xid_event:
	START TRANSACTION | COMMIT | ROLLBACK |
	SAVEPOINT A | ROLLBACK TO SAVEPOINT A | RELEASE SAVEPOINT A |
	implicit_commit ;

implicit_commit:
	# CREATE DATABASE ic ; CREATE TABLE ic . _letter SELECT * FROM _table LIMIT digit ; DROP DATABASE ic |
	# CREATE USER _letter | DROP USER _letter | RENAME USER _letter TO _letter |
	SET AUTOCOMMIT = ON | SET AUTOCOMMIT = OFF |
	# CREATE TABLE IF NOT EXISTS _letter ENGINE = engine SELECT * FROM _table LIMIT digit |
	# RENAME TABLE _letter TO _letter |
	# TRUNCATE TABLE _letter |
	# DROP TABLE IF EXISTS _letter |
	{ return $safety_check } LOCK TABLE _table WRITE ; { return $safety_check } UNLOCK TABLES |
	{ return $safety_check } SELECT * FROM _table LIMIT digit INTO OUTFILE tmpnam ; { return $safety_check } LOAD DATA INFILE tmpnam REPLACE INTO TABLE _table ;

begin_load_query_event:
	binlog_format_statement ; load_data_infile ; binlog_format_restore ;

execute_load_query_event:
	binlog_format_statement ; load_data_infile ; binlog_format_restore ;

load_data_infile:
	SELECT * FROM _table ORDER BY _field LIMIT digit INTO OUTFILE tmpnam ; LOAD DATA INFILE tmpnam REPLACE INTO TABLE _table ;


insert_rows_event:
	binlog_format_row ; { return $safety_check } insert ; binlog_format_restore ;

update_rows_event:
	binlog_format_row ; update ; binlog_format_restore ;

delete_rows_event:
	binlog_format_row ; delete ; binlog_format_restore ;

delete_statement_event:
	binlog_format_statement ; { return $safety_check } delete ; binlog_format_restore ;


single_dml_event:
	binlog_format_save ; binlog_format_set ; { return $safety_check } dml ; binlog_format_restore ;

binlog_format_save:
	{ return $safety_check } SET @binlog_format_saved = @@binlog_format ;
binlog_format_set:
	{ return $safety_check } SET BINLOG_FORMAT = rand_binlog_format ;
binlog_format_restore:
	SET BINLOG_FORMAT = @binlog_format_saved ;
rand_binlog_format:
	'STATEMENT' | 'MIXED' | 'ROW' ;
dml:
	update | delete | insert ;

sequence_dml_event:
   binlog_format_save ; binlog_format_set ; { return $safety_check } dml ; { return $safety_check } dml ; { return $safety_check } dml ; { return $safety_check } dml ; binlog_format_restore ;
	


# MLML

delete:
	# Delete in one table, search in one table
	# Unsafe in statement based replication DELETE       FROM _table            LIMIT 1                 |
	DELETE       FROM _table               where |
	# Delete in two tables, search in two tables
	DELETE A , B FROM _table AS A join     where |
	# Delete in one table, search in two tables
	DELETE A     FROM _table AS A where subquery ;
	DELETE A     FROM _table AS A where union where ;
join:
	# Do not place a where condition here.
	NATURAL JOIN _table B ;
subquery:
	correlated | non_correlated ;
subquery_part1:
	AND A.`pk` IN ( SELECT `pk` FROM _table AS B  ;
correlated:
	subquery_part1 WHERE B.`pk` = A.`pk` ) ;
non_correlated:
	subquery_part1 ) ;
where:
	WHERE `pk` BETWEEN _digit[invariant] AND _digit[invariant] + 1 ;

insert:
	# mleich: Does an additional "on_duplicate_key_update" give an advantage?
	# Insert into one table, search in no other table
	INSERT INTO _table ( _field ) VALUES ( value ) |
	# Insert into one table, search in >= 1 tables
	INSERT INTO _table ( _field_list[invariant] ) SELECT _field_list[invariant] FROM table_in_select AS A addition ;

table_in_select:
	_table                                        |
	( SELECT _field_list[invariant] FROM _table ) ;

addition:
	where | where subquery | join where | where union where ;

union:
	UNION SELECT _field_list[invariant] FROM table_in_select as B ;

update:
   # mleich: Search within another table etc. should be covered by "delete" and "insert".
	# Update one table
	UPDATE _table SET _field = value where |
	# Update two tables
	UPDATE _table AS A join SET A. _field = value , B. _field = _digit where ;

# MLML

ddl:
	CREATE TRIGGER _letter trigger_time trigger_event ON _table FOR EACH ROW BEGIN procedure_body ; END |
	CREATE EVENT IF NOT EXISTS _letter ON SCHEDULE EVERY digit SECOND ON COMPLETION PRESERVE DO BEGIN procedure_body ; END ;
	CREATE PROCEDURE _letter () BEGIN procedure_body ; END ;

trigger_time:
        BEFORE | AFTER ;

trigger_event:
        INSERT | UPDATE ;

procedure_body:
	binlog_event ; binlog_event ; binlog_event ; CALL _letter () ;

engine:
	Innodb | MyISAM ;

# where:
	# WHERE _field > value |
	# WHERE _field < value |
	# WHERE _field = value ;

order_by:
	| ORDER BY _field ;

limit:
	| LIMIT digit ;

value:
	_digit | _english | NULL | CONNECTION_ID() | LAST_INSERT_ID() ;
