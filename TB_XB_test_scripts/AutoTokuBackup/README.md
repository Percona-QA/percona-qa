
MySQL-AutoTokuBackup
====================

MySQL AutoTokuBackup commandline tool written in Python 3.
You can use this script for automate usage of Percona TokuBackup.



Requirements:
-------------

    * Percona Server with enabled TokuBackup plugin
    * Python 3 (tested version 3.5.3)
    * Official mysql-connector-python (>= 2.0.2 )
    * Python Click package (>= 3.3)
    * watchdog>=0.8.3
    


Installing
-----------------

    cd /home
    git clone https://github.com/Percona-QA/percona-qa
    cd percona-qa/TB_XB_test_scripts/AutoTokuBackup
    python3 setup.py install
    
    
Project Structure:
------------------

    
    Percona TokuBackup open-source hot backup tool for TokuDB engine.
    Here is project path tree:
    
        * backup                        -- Backup main logic goes here.(backup_calculation.py)
		* general_conf                  -- All-in-one config file and config reader class(generalops.py).
    	* setup.py                      -- Setuptools Setup file.
    	* tokubackup.py                 -- Commandline Tool provider script.
    	* /etc/tokubackup.conf          -- Main config file will be created from general_conf/tokubackup.conf file
    	


General Usage:
-----
        1. Clone repository to local directory. 
        2. Install using setup script.
        3. Edit /etc/tokubackup.conf file to reflect your settings and start to use.
        

Sample Output:
----------

    tokubackup --help
    Usage: tokubackup [OPTIONS]

    Options:
    --backup   Take full backup using TokuBackup.
    --version  Version information.
    --help     Show this message and exit.

      
      
    # tokubackup --version
    Developed by Shahriyar Rzayev from Percona
    Link : https://github.com/Percona-QA/percona-qa
    Email: shahriyar.rzayev@percona.com
    Based on Percona TokuBackup: https://www.percona.com/doc/percona-server/5.6/tokudb/toku_backup.html
    MySQL-AutoTokuBackup Version 1.0

    
    
    # tokubackup --backup
    Backup will be stored in  /var/lib/tokubackupdir/2017-01-31_14-15-46
    Running backup command => /home/sh/percona-server/5.7.16/bin/mysql -uroot --password=msandbox --host=localhost --socket=/tmp/mysql_sandbox5716.sock -e set tokudb_backup_dir='/var/lib/tokubackupdir/2017-01-31_14-15-46'
    mysql: [Warning] Using a password on the command line interface can be insecure.
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/__tokudb_lock_dont_delete_me_data
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/__tokudb_lock_dont_delete_me_logs
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/__tokudb_lock_dont_delete_me_temp
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/log000000000006.tokulog29
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/tokudb.rollback
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/tokudb.environment
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/tokudb.directory
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/tc.log
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/client-key.pem
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/server-cert.pem
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/server-key.pem
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/ca.pem
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/ca-key.pem
    Created file in backup directory -> /var/lib/tokubackupdir/2017-01-31_14-15-46/mysql_data_dir/auto.cnf
    Completed - OK


Supplementary Files
-------------------

The original MySQL configuration file as well as, MySQL Global and Session variable values will be stored in backup directory:


    # ls 2017-01-31_14-15-46/
    global_variables  mysql_data_dir  original.my.cnf  session_variables




