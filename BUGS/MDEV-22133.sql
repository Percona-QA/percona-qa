RENAME TABLE mysql.procs_priv TO mysql.procs_gone;
CREATE USER a@localhost;

RENAME TABLE mysql.procs_priv TO mysql.procs_priv_backup;  # MDEV-22319 dup of MDEV-22133
DROP USER a;
