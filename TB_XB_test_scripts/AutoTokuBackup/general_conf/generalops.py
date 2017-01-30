#!/opt/Python3/bin/python3

import configparser
from os.path import isfile
import sys

class GeneralClass:

    def __init__(self, config='/etc/tokubackup.conf'):

        if isfile(config):
            con = configparser.ConfigParser()
            con.read(config)

            DB = con['MySQL']
            self.mysql = DB['mysql']
            self.user = DB['user']
            self.password = DB['password']
            self.port = DB['port']
            self.socket = DB['socket']
            self.host = DB['host']
            self.datadir = DB['datadir']

            ######################################################

            BCK = con['Backup']
            self.backupdir = BCK['backupdir']

        else:
            print("Missing config file : /etc/tokubackup.conf")
            sys.exit(-1)

