import sys
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

# Calculating Backup progress Logic from -> David Bennett (david.bennett@percona.com)
# Developed by Shako (shahriyar.rzayev@percona.com)
# Usage info:
# Run script from Python3 and specify backup directory to watch.
# It will calculate and show which files backed up in real-time.

class CheckMySQLEnvironment(GeneralClass):

    # Constructor
    def __init__(self):
        super().__init__()
        self.variable_values=[]
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
        cursor = self.cursor
        select_version = "select @@version"
        try:
            cursor.execute(select_version)
            for i in cursor:
                return i[0]
        except mysql.connector.Error as err:
            print("Something went wrong in check_mysql_version(): {}".format(err))


    def get_tokudb_variable_value(self, variable_name):

        cursor = self.cursor

        select_56 = "select variable_value from information_schema.global_variables where variable_name='%s'" % variable_name
        select_57 = "select variable_value from performance_schema.global_variables where variable_name='%s'" % variable_name

        try:
            mysql_version = self.check_mysql_version()
            if '5.6' in mysql_version:
                cursor.execute(select_56)
            elif '5.7' in mysql_version:
                cursor.execute(select_57)

            for i in cursor:
                if i[0] != '/var/lib/mysql':
                    self.variable_values.append(i[0])

        except mysql.connector.Error as err:
            print("Something went wrong in get_tokudb_variable_value(): {}".format(err))


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
        cursor = self.cursor

        global_variables = join(backupdir, "global_variables")
        session_variables = join(backupdir,"session_variables")


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

        # Backuper command

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

    def __init__(self):
        #initialize MySQL datadir and backup directory here
        self.chck = CheckMySQLEnvironment()
        self.datadir = self.chck.datadir
        self.backup_dir = self.chck.create_backup_directory()
        self.chck.get_tokudb_variable_value('tokudb_data_dir')
        self.chck.get_tokudb_variable_value('tokudb_log_dir')
        self.variable_values_list = self.chck.variable_values


    def calculate_progress(self, src_path_size, dest_path_size):
        # Calculate percentage

        percentage = float(dest_path_size)/float(src_path_size)*100
        return percentage

    def get_size_of_folder(self, get_path):
        # Get size of folder

        get_size_command = "du -bs %s | cut -f1" % get_path

        status, output = subprocess.getstatusoutput(get_size_command)
        if status == 0:
            size_in_bytes = output
            return size_in_bytes
        else:
            print("error")


    def final_calculation(self, event):
        # Print result of percentage calculation

        if len(self.variable_values_list) != 0:
            source_folder_size = self.get_size_of_folder(self.datadir)
            dest_folder_size = self.get_size_of_folder(self.backup_dir)
            for i in self.variable_values_list:
                tokudb_path_size = self.get_size_of_folder(i)
                source_folder_size = float(source_folder_size) + float(tokudb_path_size)

        else:
            source_folder_size = self.get_size_of_folder(self.datadir)
            dest_folder_size = self.get_size_of_folder(self.backup_dir)


        percentage = self.calculate_progress(source_folder_size, dest_folder_size)
        print("Created file in backup directory -> {}".format(event.src_path))
        print("Backup completed {} %".format(int(percentage)), end='\r')
        sys.stdout.flush()


    # def dispatch(self, event):
    #
    #     self.final_calculation(event)

    def on_created(self, event):
         #print("Created -> ", event.src_path)
         self.final_calculation(event)

    # def on_modified(self, event):
    #      print("Modified -> ", event.src_path)

    # def on_moved(self, event):
    #     print("Moved -> ", event.src_path)

    # def on_any_event(self, event):
    #     print("On Any Event -> " , event.src_path)






# class PausingObserver(Observer):
#     def dispatch_events(self, *args, **kwargs):
#         if not getattr(self, '_is_paused', False):
#             super(PausingObserver, self).dispatch_events(*args, **kwargs)
#
#     def pause(self):
#         self._is_paused = True
#
#     def resume(self):
#         #time.sleep(10)  # sleep time for observer
#         self.event_queue.queue.clear()
#         self._is_paused = False





if __name__ == "__main__":
    observer_stop = True
    a = CheckMySQLEnvironment()
    #dest_path = sys.argv[1]
    event_handler = BackupProgressEstimate()
    backupdir = event_handler.backup_dir
    print("Backup will be stored in ", backupdir)
    if isdir(backupdir):
        a.run_backup(backup_dir=backupdir)
        a.create_mysql_variables_info(backup_dir=backupdir)
        if hasattr(a, 'mysql_defaults_file') and isfile(a.mysql_defaults_file):
            a.copy_mysql_config_file(a.mysql_defaults_file, backup_dir=backupdir)
        else:
            print("The original MySQL config file is missing check if it is specified and exists!")
        observer_stop = False
    else:
        print("Specified backup directory does not exist! Check /etc/tokubackup.conf")
        sys.exit(-1)
    #observer = PausingObserver()
    observer = Observer()
    #event_handler = BackupProgressEstimate()
    observer.schedule(event_handler, backupdir, recursive=True)
    observer.start()
    try:
        if observer_stop:
            while observer_stop:
                time.sleep(1)
        else:
            observer.stop()
    except KeyboardInterrupt:
        observer.stop()
    observer.join()