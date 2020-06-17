SET SQL_MODE='';
SET @cmd="ALTER TABLE non.existing ENGINE=NDB";
PREPARE stmt FROM @cmd;
EXECUTE stmt;
EXECUTE stmt;
