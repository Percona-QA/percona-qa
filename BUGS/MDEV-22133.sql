RENAME TABLE mysql.procs_priv TO mysql.procs_gone;
CREATE USER a@localhost;

RENAME TABLE mysql.procs_priv TO mysql.procs_priv_backup;  # MDEV-22319 dup of MDEV-22133
DROP USER a;

RENAME TABLE mysql.procs_priv TO procs_priv_backup;
RENAME USER '0'@'0' to '0'@'0';

RENAME TABLE mysql.procs_priv TO mysql.procs_gone;
RENAME USER _B@'' TO _C@'';
