#!/opt/Python3/bin/python3

import configparser
from os.path import isfile
import sys

class GeneralClass(object):

    def __init__(self, config='/etc/tokubackup.conf'):

        if isfile(config):
            con = configparser.ConfigParser()
            con.read(config)

            DB = con['MySQL']
            self.mysql = DB['mysql']
            print(self.mysql)
            self.mysql_user = DB['user']
            print(self.mysql_user)
            self.mysql_password = DB['password']
            print(self.mysql_user)
            self.mysql_port = DB['port']
            print(self.mysql_port)
            if 'socket' in DB:
                self.mysql_socket = DB['socket']
            self.mysql_host = DB['host']
            self.datadir = DB['datadir']

            ######################################################

            BCK = con['Backup']
            self.backupdir = BCK['backupdir']

        else:
            print("Missing config file : /etc/tokubackup.conf")
            sys.exit(-1)

