# Created by Shahriyar Rzayev from Percona

# MySQL X Shell tests

from subprocess import Popen, check_output, PIPE
from shlex import split
import re

def mysqlsh_db_get_collections(user, passw, port):
    command = "mysqlsh {}:{}@localhost/generated_columns_test --port={} --py --interactive --execute 'db.get_collections()'"
    new_command = command.format(user, passw, port)
    try:
        prc = check_output(new_command, shell=True)
        print prc
        returned_list = re.findall(r"(?<=\<).*?(?=\>)", prc)
        print returned_list
    except Exception as e:
        print(e)
    else:
        return 0

mysqlsh_db_get_collections('bakux', 'Baku12345', 33060)
