# Causes hangs on 10.4-10.5.4, and hangs on 10.1-10.3 on shutdown
USE test;
SET GLOBAL aria_group_commit=1;
SET GLOBAL aria_group_commit_interval=CAST(-1 AS UNSIGNED INT);
CREATE TABLE t (c INT KEY) ENGINE=Aria;
CREATE USER 'a' IDENTIFIED BY 'a';
# Shutdown
