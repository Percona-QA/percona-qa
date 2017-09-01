# Created by Shahriyar Rzayev from Percona

import mysqlx

class MyXPluginLocks:
    # The Class for using X Plugin to run SQL statements
    def __init__(self):
        # Connect to a dedicated MySQL server
        self.session = mysqlx.get_session({
            'host': 'localhost',
            'port': 33060,
            'user': 'bakux',
            'password': 'Baku12345',
            'ssl-mode': mysqlx.SSLMode.DISABLED
        })


    def __del__(self):
        self.session.close()

    def create_schema(self, schema_name):
        # Creating schema
        db_obj = self.session.create_schema(schema_name)
        return db_obj.get_name()

    def create_table(self, schema_name, table_name):
        try:
            command = "create table {}.{}(id int, name varchar(25))  engine=rocksdb"
            sql = self.session.sql(command.format(schema_name, table_name))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def insert_dummy_data_into_table(self, schema_name, table_name, value_id, value_name):
        try:
            command = "insert into {}.{}(id, name) values({},'{}')"
            sql = self.session.sql(command.format(schema_name, table_name, value_id, value_name))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_lock_in_share_select(self, schema_name, table_name, value_id):
        try:
            command = "select name from {}.{} where id={} LOCK IN SHARE MODE"
            sql = self.session.sql(command.format(schema_name, table_name, value_id))
            sql.execute()
        except mysqlx.errors.OperationalError as e:
            raise mysqlx.errors.OperationalError("GAP Locks detection!")
        except Exception as e:
            raise
        else:
            return 0

    def run_for_update(self, schema_name, table_name, value_id):
        try:
            command = "select * from {}.{} where id={} FOR UPDATE"
            sql = self.session.sql(command.format(schema_name, table_name, value_id))
            sql.execute()
            cursor.fetch_all()
        except mysqlx.errors.OperationalError as e:
            raise mysqlx.errors.OperationalError("GAP Locks detection!")
        except Exception as e:
            raise
        else:
            return 0

    def run_update_statement(self, schema_name, table_name, value_id, value_name):
        try:
            command = "update {}.{} set name='{}' where id={}"
            sql = self.session.sql(command.format(schema_name, table_name, value_name, value_id))
            sql.execute()
        except mysqlx.errors.OperationalError as e:
            raise mysqlx.errors.OperationalError("GAP Locks detection!")    
        except Exception as e:
            raise
        else:
            return 0

    def start_transaction(self):
        self.session.start_transaction()

    def commit_transaction(self):
        self.session.commit()
