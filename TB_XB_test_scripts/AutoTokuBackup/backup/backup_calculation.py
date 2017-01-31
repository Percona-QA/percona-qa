import sys
from queue import Queue, Empty
import time
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer
import subprocess
import mysql.connector
import shlex
from general_conf.generalops import GeneralClass
from os.path import isdir, isfile
from os.path import join
from os import makedirs
from datetime import datetime
from shutil import copy

# Developed by Shako (shahriyar.rzayev@percona.com)
# Usage info:
# Run script from Python3 and specify backup directory to watch.
# It will calculate and show which files backed up in real-time.

class CheckMySQLEnvironment(GeneralClass):

    # Constructor
    def __init__(self):
        super().__init__()
        self.cnx = mysql.connector.connect(user=self.mysql_user,
                                           password=self.mysql_password,
                                           host=self.mysql_host,
                                           port=self.mysql_port)
        self.cursor = self.cnx.cursor()

    # Desctructor
    def __del__(self):
        self.cursor.close()
        self.cnx.close()


    def check_mysql_version(self):
        """
        Check for MySQL version
        """
        cursor = self.cursor
        select_version = "select @@version"
        try:
            cursor.execute(select_version)
            for i in cursor:
                return i[0]
        except mysql.connector.Error as err:
            print("Something went wrong in check_mysql_version(): {}".format(err))




    def copy_mysql_config_file(self, defaults_file, backup_dir):
        """
        Copy the passed MySQL configuration file to backup directory.
        :return: True, if file successfully copied.
        :return: Error, if error occured during copy operation.
        """
        try:

            backup_dir += "/"+"original.my.cnf"
            copy(defaults_file, backup_dir)
            return True

        except Exception as err:
            print("Something went wrong in copy_mysql_config_file(): {}".format(err))


    def create_mysql_variables_info(self, backup_dir):
        """
        Capturing MySQL global and session variables and putting inside 2 separate files.
        :param backup_dir:
        """
        cursor = self.cursor

        global_variables = join(backup_dir, "global_variables")
        session_variables = join(backup_dir,"session_variables")


        select_global_56 = "select variable_name, variable_value from information_schema.global_variables"
        select_session_56 = "select variable_name, variable_value from information_schema.session_variables"

        select_global_57 = "select variable_name, variable_value from performance_schema.global_variables"
        select_session_57 = "select variable_name, variable_value from performance_schema.session_variables"

        try:
            mysql_version = self.check_mysql_version()
            if '5.6' in mysql_version:
                cursor.execute(select_global_56)
                with open(global_variables, "w") as f:
                    for i in cursor:
                        str = i[0] + " ==> " + i[1] + "\n"
                        f.write(str)

                cursor.execute(select_session_56)
                with open(session_variables, "w") as f:
                    for i in cursor:
                        str = i[0] + " ==> " + i[1] + "\n"
                        f.write(str)

            elif '5.7' in mysql_version:
                cursor.execute(select_global_57)
                with open(global_variables, "w") as f:
                    for i in cursor:
                        str = i[0] + " ==> " + i[1] + "\n"
                        f.write(str)

                cursor.execute(select_session_57)
                with open(session_variables, "w") as f:
                    for i in cursor:
                        str = i[0] + " ==> " + i[1] + "\n"
                        f.write(str)

        except mysql.connector.Error as err:
            print("Something went wrong in create_mysql_variables_info(): {}".format(err))
        except Exception as err:
            print("Something went wrong in create_mysql_variables_info(): {}".format(err))



    def create_backup_directory(self):
        """
        Creating timestamped backup directory.
        :return: Newly created backup directory or Error.
        """
        new_backup_dir = join(self.backupdir, datetime.now().strftime('%Y-%m-%d_%H-%M-%S'))
        try:
            # Creating backup directory
            makedirs(new_backup_dir)
            # Changing owner
            chown_command = "chown mysql:mysql %s" % new_backup_dir
            status, output = subprocess.getstatusoutput(chown_command)
            if status == 0:
                return new_backup_dir
            else:
                print("Could not change owner of backup directory!")
        except Exception as err:
            print("Something went wrong in create_backup_directory(): {}".format(err))


    def run_backup(self, backup_dir):
        """
        Running actual backup command to MySQL server.
        :param backup_dir:
        """


        backup_command_connection = '{} -u{} --password={} --host={}'
        backup_command_execute = ' -e "set tokudb_backup_dir=\'{}\'"'


        try:

            if hasattr(self, 'mysql_socket'):
                backup_command_connection += ' --socket={}'
                backup_command_connection += backup_command_execute
                new_backup_command = shlex.split(backup_command_connection.format(self.mysql,
                                                                       self.mysql_user,
                                                                       self.mysql_password,
                                                                       self.mysql_host,
                                                                       self.mysql_socket,
                                                                       backup_dir))
            else:
                backup_command_connection += ' --port={}'
                backup_command_connection += backup_command_execute
                new_backup_command = shlex.split(backup_command_connection.format(self.mysql,
                                                                   self.mysql_user,
                                                                   self.mysql_password,
                                                                   self.mysql_host,
                                                                   self.mysql_port,
                                                                   backup_dir))
            # Do not return anything from subprocess
            print("Running backup command => %s" % (' '.join(new_backup_command)))

            process = subprocess.Popen(new_backup_command, stdin=None, stdout=None, stderr=None)


        except Exception as err:
            print("Something went wrong in run_backup(): {}".format(err))










class BackupProgressEstimate(FileSystemEventHandler):

    def __init__(self, observer):
        """
        Constructor
        :param observer:
        """
        self.observer = observer
        self.chck = CheckMySQLEnvironment()
        self.datadir = self.chck.datadir
        self.backup_dir = self.chck.create_backup_directory()
        self.events_queue = Queue()


    def on_created(self, event):
        """
        Called when a file or directory is created.
        :param event:
        :return:
        """
        self.events_queue.put(event.src_path)
        print("Created file in backup directory -> {}".format(event.src_path))

    def wait_for_event(self, block=True, timeout=None):
        """
        Work with queued events
        :param block:
        :param timeout:
        :return: False if queue is empty
        """

        try:
            return self.events_queue.get(block, timeout)
        except Empty:
            return False



def main():
    a = CheckMySQLEnvironment()
    observer = Observer()
    event_handler = BackupProgressEstimate(observer=observer)
    backupdir = event_handler.backup_dir
    print("Backup will be stored in ", backupdir)
    if isdir(backupdir):
        a.run_backup(backup_dir=backupdir)
        a.create_mysql_variables_info(backup_dir=backupdir)
        if hasattr(a, 'mysql_defaults_file') and isfile(a.mysql_defaults_file):
            a.copy_mysql_config_file(a.mysql_defaults_file, backup_dir=backupdir)
        else:
            print("The original MySQL config file is missing check if it is specified and exists!")

    else:
        print("Specified backup directory does not exist! Check /etc/tokubackup.conf")
        sys.exit(-1)

    observer.schedule(event_handler, backupdir, recursive=True)
    observer.start()
    try:
        while True:
            if event_handler.wait_for_event(timeout=1) == False:
                break
    except KeyboardInterrupt:
        observer.stop()

    print("Completed - OK")
    observer.stop()
    observer.join()



if __name__ == "__main__":
    sys.exit(main())
