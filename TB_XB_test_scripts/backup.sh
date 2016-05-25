/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/etc/my.cnf --backup --keyring-file-data=/var/lib/mysql-keyring/keyring --server-id=0 --datadir=/var/lib/mysql/ --target-dir=/home/backup_dir/full/ --user=root --password=Baku12345# --no-version-check

sleep 10

/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/etc/my.cnf --backup --target-dir=/home/backup_dir/inc/inc1 --incremental-basedir=/home/backup_dir/full --datadir=/var/lib/mysql/ --user=root --password=Baku12345# --no-version-check --keyring-file-data=/var/lib/mysql-keyring/keyring --server-id=0

sleep 10

/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/etc/my.cnf --backup --target-dir=/home/backup_dir/inc/inc2 --incremental-basedir=/home/backup_dir/inc/inc1 --datadir=/var/lib/mysql/ --user=root --password=Baku12345# --no-version-check --keyring-file-data=/var/lib/mysql-keyring/keyring --server-id=0

sleep 10

/usr/local/xtrabackup/bin/xtrabackup --defaults-file=/etc/my.cnf --backup --target-dir=/home/backup_dir/inc/inc3 --incremental-basedir=/home/backup_dir/inc/inc2 --datadir=/var/lib/mysql/ --user=root --password=Baku12345# --no-version-check --keyring-file-data=/var/lib/mysql-keyring/keyring --server-id=0
