# Repeat x times on 200 theads. x is usually very small.
# mysqld options required for replay: --log-bin
RESET MASTER TO 0x7FFFFFFF;
SET GLOBAL max_binlog_size=4096;
CREATE USER user@localhost;
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
SET PASSWORD FOR user@localhost=PASSWORD('a');
