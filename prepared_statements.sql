-- create test database for prepared statement
-- -------------------------------------------
DROP DATABASE IF EXISTS pstest; CREATE DATABASE pstest;
use pstest;

-- prepared statement for table creation
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_CREATE $$
CREATE PROCEDURE PS_CREATE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("CREATE TABLE ",@tbl," (id int auto_increment,rtext varchar(50), primary key(id)) ENGINE=InnoDB");
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_CREATE();

-- prepared statement for index creation
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_INDEX $$
CREATE PROCEDURE PS_INDEX()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("CREATE INDEX itext ON ",@tbl," (rtext(10))");
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_INDEX();

-- prepared statement for insert operation
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_INSERT $$
CREATE PROCEDURE PS_INSERT() BEGIN
  DECLARE create_start  INT DEFAULT 1;
  DECLARE insert_start INT DEFAULT 1;
  DECLARE create_count  INT DEFAULT 10;
  DECLARE insert_count INT DEFAULT 100;
    WHILE create_start <= create_count DO
      SET @tbl = concat("tbl",create_start);
      WHILE insert_start <= insert_count DO
        SELECT SUBSTRING(MD5(RAND()) FROM 1 FOR 50) INTO @str;
        SET @s = concat("INSERT INTO ",@tbl," (rtext) VALUES('",@str,"')");
        PREPARE stmt1 FROM @s;
        EXECUTE stmt1;
        SET insert_start = insert_start + 1;
      END WHILE;
      SET create_start=create_start+1;
	  SET insert_start = 1;
    END WHILE;
END $$
DELIMITER ;

CALL PS_INSERT();

-- prepared statement for delete operation
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_DELETE $$
CREATE PROCEDURE PS_DELETE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("DELETE FROM ",@tbl ," ORDER BY RAND() LIMIT 45");
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_DELETE();

-- prepared statement for analyze table
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_ANALYZE $$
CREATE PROCEDURE PS_ANALYZE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("ANALYZE TABLE ",@tbl);
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_ANALYZE();

-- prepared statement for delete operation
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_DELETE $$
CREATE PROCEDURE PS_DELETE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("DELETE FROM ",@tbl ," ORDER BY RAND() LIMIT 35");
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_DELETE();

-- prepared statement for optimize table
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_OPT_TABLE $$
CREATE PROCEDURE PS_OPT_TABLE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("OPTIMIZE TABLE ",@tbl);
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_OPT_TABLE();

-- prepared statement for update operation
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_UPDATE $$
CREATE PROCEDURE PS_UPDATE()    BEGIN
  DECLARE create_start  INT DEFAULT 1;
  DECLARE update_start INT DEFAULT 1;
  DECLARE create_count  INT DEFAULT 10;
  DECLARE update_count INT DEFAULT 50;
    WHILE create_start <= create_count DO
      SET @tbl = concat("tbl",create_start);
      WHILE update_start <= update_count DO
        SELECT SUBSTRING(MD5(RAND()) FROM 1 FOR 50) INTO @ustr;
        SET @s = concat("UPDATE ",@tbl ," SET rtext='",@ustr,"' ORDER BY RAND() LIMIT 1");
        PREPARE stmt1 FROM @s;
        EXECUTE stmt1;
        SET update_start = update_start + 1;
      END WHILE;
      SET create_start=create_start+1;
	  SET update_start = 1;
    END WHILE;
END $$
DELIMITER ;

CALL PS_UPDATE();

-- prepared statement for repair table
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_RPR_TABLE $$
CREATE PROCEDURE PS_RPR_TABLE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("REPAIR TABLE ",@tbl);
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_RPR_TABLE();

-- prepared statement for drop index
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_DROP_INDEX $$
CREATE PROCEDURE PS_DROP_INDEX()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("DROP INDEX itext ON ",@tbl);
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_DROP_INDEX();

-- prepared statement for truncate table
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_TRUNCATE $$
CREATE PROCEDURE PS_TRUNCATE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("TRUNCATE TABLE ",@tbl);
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_TRUNCATE();

-- prepared statement for drop table
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_DROP_TABLE $$
CREATE PROCEDURE PS_DROP_TABLE()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tbl = concat("tbl",a);
      SET @s = concat("DROP TABLE ",@tbl);
	  PREPARE stmt1 FROM @s;
      EXECUTE stmt1;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_DROP_TABLE();

-- prepared statement for create user
DELIMITER $$
DROP PROCEDURE IF EXISTS PS_CREATE_USER $$
CREATE PROCEDURE PS_CREATE_USER()    BEGIN
  DECLARE a INT Default 1 ;
    WHILE a <= 10 DO
	  SET @tuser = concat("testuser",a);
      SET @s = concat("CREATE USER ",@tuser,"@'%' IDENTIFIED BY 'test123'");
      SET @t = concat("GRANT ALL ON *.* TO ",@tuser,"@'%'");
	  PREPARE stmt1 FROM @s;
	  PREPARE stmt2 FROM @t;
      EXECUTE stmt1;
      EXECUTE stmt2;
      SET a=a+1;
   END WHILE;
END $$
DELIMITER ;

CALL PS_CREATE_USER();

