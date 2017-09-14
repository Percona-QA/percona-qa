import mysqlx
import pytest

class RocksBulk:
    # The Class for Rocksdb Bulk Load
    def __init__(self):
        # Connect to a dedicated MySQL server
        self.session = mysqlx.get_session({
            'host': 'localhost',
            'port': 33060,
            'user': 'bakux',
            'password': 'Baku12345',
            'ssl-mode': mysqlx.SSLMode.DISABLED
        })


    def start_transaction(self):
        self.session.start_transaction()

    def commit_transaction(self):
        self.session.commit()

    def run_set_sql_log_bin(self, value):
        try:
            command = "SET session sql_log_bin={}"
            sql = self.session.sql(command.format(value))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_set_rocksdb_bulk_load(self, value):
        try:
            command = "SET session rocksdb_bulk_load={}"
            sql = self.session.sql(command.format(value))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_alter_drop_foreign_key(self, schema_name, table_name):
        try:
            command = "alter table {}.{} drop foreign key salaries_ibfk_1"
            sql = self.session.sql(command.format(schema_name, table_name))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_alter_storage_engine(self, schema_name, table_name, engine):
        try:
            command = "alter table {}.{} engine={}"
            sql = self.session.sql(command.format(schema_name, table_name, engine))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_create_table(self, schema_name, table_name, from_schema_name, from_table_name):
        try:
            command = "create table {}.{} like {}.{}"
            sql = self.session.sql(command.format(schema_name, table_name, from_schema_name, from_table_name))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_insert_statement(self, schema_name, table_name, emp_no, from_date):
        try:
            command = "insert into {}.{} select * from {}.salaries where emp_no={} and from_date='{}'"
            sql = self.session.sql(command.format(schema_name, table_name, schema_name, emp_no, from_date))
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def run_select_statement(self, schema_name, table_name):
        try:
            command = "select count(*) from {}.{}"
            sql = self.session.sql(command.format(schema_name, table_name))
            cursor = sql.execute()
        except Exception as e:
            raise
        else:
            return cursor
