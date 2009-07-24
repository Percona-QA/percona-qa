query:
	insert | update | delete | transaction | load_data_infile;


transaction:
	START TRANSACTION | COMMIT | ROLLBACK |
	SAVEPOINT A | ROLLBACK TO SAVEPOINT A | RELEASE SAVEPOINT A |
	implicit_commit ;

implicit_commit:
	CREATE DATABASE implicit_commit ; CREATE TABLE implicit_commit . _letter SELECT * FROM _table LIMIT digit ; DROP DATABASE implicit_commit |
	SET AUTOCOMMIT = ON | SET AUTOCOMMIT = OFF |
	CREATE TABLE IF NOT EXISTS _letter ENGINE = engine SELECT * FROM _table LIMIT digit |
	RENAME TABLE _letter TO _letter |
	TRUNCATE TABLE _letter |
	DROP TABLE IF EXISTS _letter |
	LOCK TABLE _table WRITE ; UNLOCK TABLES ;

load_data_infile:
	SELECT * FROM _table ORDER BY _field LIMIT digit INTO OUTFILE tmpnam ; LOAD DATA INFILE tmpnam REPLACE INTO TABLE _table ;

insert:
	INSERT INTO _table ( _field , _field , _field , _field ) VALUES ( value , value , value , value ) |
	INSERT INTO _table ( _field , _field , _field ) VALUES ( value , value , value ) |
	INSERT INTO _table ( _field , _field ) VALUES ( value , value ) |
	INSERT INTO _table SELECT * FROM _table LIMIT digit ;

update:
	UPDATE _table SET _field = value where order_by limit ;

delete:
	DELETE FROM _table where LIMIT digit ;

where:
	WHERE _field > value |
	WHERE _field < value |
	WHERE _field = value ;

order_by:
	| ORDER BY _field ;

limit:
	| LIMIT digit ;

value:
	_digit | _letter | _english | _data | 
	_digit | _letter | _english | _data | NULL ;
