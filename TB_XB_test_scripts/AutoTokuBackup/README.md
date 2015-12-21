
MySQL-AutoTokuBackup
====================

MySQL AutoTokuBackup commandline tool written in Python 3.
You can use this script for automate usage of Percona TokuBackup.



Requirements:
-------------

    * Percona Server with enabled TokuBackup plugin
    * Python 3 (tested version 3.3.2)
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

    root@percona-XPS-15:~# /opt/Python3/bin/tokubackup --help
    Usage: tokubackup [OPTIONS]

    Options:
      --backup   Take full backup using TokuBackup.
      --version  Version information.
      --help     Show this message and exit.
      
      
    root@percona-XPS-15:~# /opt/Python3/bin/tokubackup --version
    Developed by Shahriyar Rzayev from Percona
    Link : https://github.com/Percona-QA/percona-qa
    Email: shahriyar.rzayev@percona.com
    Based on Percona TokuBackup: https://www.percona.com/doc/percona-server/5.6/tokudb/toku_backup.html
    MySQL-AutoTokuBackup Version 1.0
    
    
    root@percona-XPS-15:~# /opt/Python3/bin/tokubackup --backup
    Warning: Using a password on the command line interface can be insecure.
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/debian-5.6.flag
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/mysql-bin.000132
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/mysql-bin.000096
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/mysql-bin.000114
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/mysql-bin.000135
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/mysql-bin.000074
    Created file in backup directory -> /home/tokubackupdir/mysql_data_dir/mysql-bin.000146
    Backup completed 15%


