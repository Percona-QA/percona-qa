# Created by Shahriyar Rzayev from Percona

# MySQL X Shell tests

from subprocess import Popen

def mysqlsh_db_get_collections(user, passw, port):
    command = "mysqlsh {}:{}@localhost/generated_columns_test --port={} --py --interactive --execute 'db.get_collections()'"
    new_command = command.format(user, passw, port)
    try:
        process = Popen(
                    split(new_command),
                    stdin=None,
                    stdout=None,
                    stderr=None)
        output, error = process.communicate()
        print output
    except Exception as e:
        print(e)
    else:
        return 0

mysqlsh_db_get_collections('bakux', 'Baku12345', 33060)
