/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/home/backup_dir/full/backup-my.cnf --prepare --apply-log-only --target-dir=/home/backup_dir/full --keyring-file-data=/var/lib/mysql-keyring/keyring --reencrypt-for-server-id=5

sleep 10

/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/home/backup_dir/full/backup-my.cnf --prepare --apply-log-only --target-dir=/home/backup_dir/full --incremental-dir=/home/backup_dir/inc/inc1 --keyring-file-data=/var/lib/mysql-keyring/keyring --reencrypt-for-server-id=5

sleep 10

/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/home/backup_dir/full/backup-my.cnf --prepare --apply-log-only --target-dir=/home/backup_dir/full --incremental-dir=/home/backup_dir/inc/inc2 --keyring-file-data=/var/lib/mysql-keyring/keyring --reencrypt-for-server-id=5

sleep 10

/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/home/backup_dir/full/backup-my.cnf --prepare --target-dir=/home/backup_dir/full --incremental-dir=/home/backup_dir/inc/inc3 --keyring-file-data=/var/lib/mysql-keyring/keyring --reencrypt-for-server-id=5
