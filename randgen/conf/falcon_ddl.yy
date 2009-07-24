query:
	dml | dml | dml | dml | dml | dml | dml | dml | dml | dml |
	dml | dml | dml | dml | dml | dml | dml | dml | dml | dml |
	database | tablespace | table |
	alter | show | transaction | use ;

select:
	SELECT _field FROM _letter WHERE where_cond group_by limit;

dml:
	update | insert | select | delete ;

group_by:
	| GROUP BY _field ;

limit:
	| LIMIT _digit ;

where_cond:
	_field < _digit;

insert:
	INSERT INTO _letter ( _field , _field ) VALUES ( _digit , _digit ) ;

update:
	UPDATE _letter SET _field = _digit WHERE where_cond limit ;

delete:
	DELETE FROM _letter WHERE where_cond LIMIT _digit;

transaction:
	START TRANSACTION | COMMIT | ROLLBACK | SAVEPOINT A | ROLLBACK TO SAVEPOINT A ;

use:
	USE _letter ;

database:
	create_database | create_database | create_database | create_database | create_database |
	drop_database ;

create_database:
	CREATE DATABASE IF NOT EXISTS _letter ;

drop_database:
	DROP DATABASE IF EXISTS _letter ;

tablespace:
	create_tablespace | create_tablespace | create_tablespace | create_tablespace | create_tablespace |
	drop_tablespace ;

create_tablespace:
	CREATE TABLESPACE _letter ADD DATAFILE ' _letter . TABLESPACE ' ENGINE = Falcon ;

drop_tablespace:
	DROP TABLESPACE _letter ENGINE = Falcon ;

table:
	create_table | create_table | create_table | create_table | create_table |
	drop_table | rename_table | truncate_table ;

create_table:
	CREATE TEMPORARY TABLE IF NOT EXISTS _letter TABLESPACE _letter SELECT * FROM _letter |
	CREATE TABLE IF NOT EXISTS _letter (`pk` INTEGER AUTO_INCREMENT NOT NULL , PRIMARY KEY (`pk`) ) TABLESPACE _letter |
	CREATE TABLE IF NOT EXISTS _letter (`pk` INTEGER ) partition ;

drop_table:
	DROP TABLE IF EXISTS _letter ;

rename_table:
	RENAME TABLE _letter TO _letter |
	RENAME TABLE _letter . _letter TO _letter . _letter ;

truncate_table:
	TRUNCATE TABLE _letter ;

alter:
	ALTER TABLE _letter ADD PARTITION (PARTITION _letter VALUES LESS THAN ( _tinyint_unsigned ) TABLESPACE _letter ) |
	ALTER TABLE _letter DROP PARTITION _letter |
	ALTER TABLE _letter REORGANIZE PARTITION _letter INTO (
		PARTITION _letter VALUES LESS THAN ( _digit ) TABLESPACE _letter ,
		PARTITION _letter VALUES LESS THAN ( _tinyint_unsigned ) TABLESPACE _letter 
	) |
	ALTER TABLE _letter REMOVE PARTITIONING |
	ALTER TABLE _letter partition ;

partition:
	PARTITION BY KEY(`pk`) |
	PARTITION BY RANGE (`pk`) (
		PARTITION _letter VALUES LESS THAN ( _digit ) TABLESPACE _letter ,
		PARTITION _letter VALUES LESS THAN ( _tinyint_unsigned ) TABLESPACE _letter ,
		PARTITION _letter VALUES LESS THAN MAXVALUE TABLESPACE _letter
	) ;

show:
	SHOW TABLE STATUS |
	SELECT * FROM INFORMATION_SCHEMA.SCHEMATA |
	DESCRIBE _letter ;
