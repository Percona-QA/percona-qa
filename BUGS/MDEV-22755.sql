SET NAMES gbk;
SET SQL_MODE='';
CREATE USER очень_очень_очень_очень_длинный_юзер@localhost;
SELECT * FROM INFORMATION_SCHEMA.user_privileges WHERE GRANTEE LIKE "'abcdefghijklmnopqrstuvwxyz'%";
