SET NAMES latin1, COLLATION_CONNECTION=ucs2_general_ci, CHARACTER_SET_CLIENT=cp932;
SELECT SCHEMA_NAME from information_schema.schemata where schema_name='имя_базы_в_кодировке_утф8_длиной_больше_чем_45';

EXECUTE IMMEDIATE CONCAT('SELECT SCHEMA_NAME from information_schema.schemata where schema_name=''' , REPEAT('a',193), '''');

SELECT SCHEMA_NAME from information_schema.schemata where schema_name='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

SELECT SCHEMA_NAME from information_schema.schemata where schema_name=REPEAT('a',193);

SET COLLATION_CONNECTION=eucjpms_bin, SESSION CHARACTER_SET_CLIENT=cp932;
SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.schemata WHERE schema_name='имя_базы_в_кодировке_утф8_длиной_больше_чем_45';
