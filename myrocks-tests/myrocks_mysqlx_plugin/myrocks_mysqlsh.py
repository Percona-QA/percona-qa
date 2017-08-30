# Created by Shahriyar Rzayev from Percona

# MySQL X Shell tests

from subprocess import Popen, check_output, PIPE
from shlex import split
import re

def mysqlsh_db_get_collections(user, passw, port):
    # Function for calling db.get_collections()
    # Should return empty list
    command = "mysqlsh {}:{}@localhost/generated_columns_test --port={} --py --interactive --execute 'db.get_collections()'"
    new_command = command.format(user, passw, port)
    try:
        prc = check_output(new_command, shell=True)
        returned_list = re.findall(r"(?<=\<).*?(?=\>)", prc)
        return returned_list
    except Exception as e:
        print(e)
    else:
        return 0
