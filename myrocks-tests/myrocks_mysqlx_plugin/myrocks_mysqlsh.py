# Created by Shahriyar Rzayev from Percona

# MySQL X Shell tests

from subprocess import Popen, check_output
from shlex import split

def mysqlsh_db_get_collections(user, passw, port):
    command = "mysqlsh {}:{}@localhost/generated_columns_test --port={} --py --interactive --execute 'db.get_collections()'"
    new_command = command.format(user, passw, port)
    try:
        process = Popen(
                    split(new_command), stdout=PIPE)
        output, error = process.communicate()
        print "The output:"
        print output
        # prc = check_output(new_command, shell=True)
        # print prc.split()
    except Exception as e:
        print(e)
    else:
        return 0

mysqlsh_db_get_collections('bakux', 'Baku12345', 33060)
