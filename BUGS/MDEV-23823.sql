# Sporadic issue. Run the following about 60-120 times at the CLI to reproduce
DROP DATABASE test;
CREATE DATABASE test;
USE test;
CREATE view v1 AS SELECT 'abcdefghijklmnopqrstuvwxyz' AS col1;
LOCK TABLE v1 READ;
SELECT NEXT VALUE FOR v1;
