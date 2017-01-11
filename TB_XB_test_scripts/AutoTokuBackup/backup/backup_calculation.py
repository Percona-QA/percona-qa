import sys
import time
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer
import subprocess
import mysql.connector
import shlex
from general_conf.generalops import GeneralClass
from os.path import isdir

# Script Logic from -> David Bennett (david.bennett@percona.com)
# Usage info:
# Run script from Python3 and specify backup directory to watch.
# It will calculate and show which files backed up in real-time.

class CheckMySQLEnvironment(GeneralClass):

    def __init__(self):
        GeneralClass.__init__(self)
        self.variable_values=[]




    def get_tokudb_variable_value(self, variable_name):

        cnx = mysql.connector.connect(user=self.user, password=self.password,
                              host=self.host,port=self.port)


        cursor = cnx.cursor()

        select_version = "select @@version"

        select_56 = "select variable_value from information_schema.global_variables where variable_name='%s'" % variable_name
        select_57 = "select variable_value from performance_schema.global_variables where variable_name='%s'" % variable_name
        try:
            cursor.execute(select_version)
            for i in cursor:
                if '5.6' in i[0]:
                    cursor.execute(select_56)

                elif '5.7' in i[0]:
                    cursor.execute(select_57)


            for i in cursor:
                if i[0] != '/var/lib/mysql':
                    self.variable_values.append(i[0])

        except mysql.connector.Error as err:
            print("Something went wrong: {}".format(err))

        cursor.close()
        cnx.close()



    def run_backup(self, backup_dir):

        # Backuper command

        backup_command = '{} -u{} --password={} --host={} -e "set tokudb_backup_dir=\'{}\'"'


        try:
            new_backup_command = shlex.split(backup_command.format(self.mysql, self.user, self.password, self.host, backup_dir))
            # Do not return anything from subprocess
            process = subprocess.Popen(new_backup_command, stdin=None, stdout=None, stderr=None)


        except Exception as err:
            print("Something went wrong: {}".format(err))










class BackupProgressEstimate(FileSystemEventHandler):

    def __init__(self):
        #initialize MySQL datadir and backup directory here
        self.chck = CheckMySQLEnvironment()
        self.datadir = self.chck.datadir
        self.backup_dir = self.chck.backupdir
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

    a = CheckMySQLEnvironment()
    #dest_path = sys.argv[1]
    if isdir(a.backupdir):
        a.run_backup(backup_dir=a.backupdir)
    else:
        print("Specidifed backup directory doest not exist!")
        sys.exit(-1)
    #observer = PausingObserver()
    observer = Observer()
    event_handler = BackupProgressEstimate()
    observer.schedule(event_handler, a.backupdir, recursive=True)
    observer.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()