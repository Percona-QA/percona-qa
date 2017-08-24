# Created by Shahriyar Rzayev from Percona

# Connecting to MySQL and working with a Session
import mysqlx

class MyXPlugin:

    def __init__(self, schema_name, collection_name):
        # Connect to a dedicated MySQL server
        self.session = mysqlx.get_session({
            'host': 'localhost',
            'port': 33060,
            'user': 'bakux',
            'password': 'Baku12345',
            'ssl-mode': mysqlx.SSLMode.DISABLED
        })

        self.schema_name = schema_name
        self.collection_name = collection_name

        # Getting schema object
        self.schema = self.session.get_schema(self.schema_name)
        # Creating collection
        self.schema.create_collection(self.collection_name)
        # Getting collection object
        self.collection_obj = self.schema.get_collection(self.collection_name)


    def insert_into_collection(self):
        # You can also add multiple documents at once
        print "Inserting 3 rows into collection"
        self.collection_obj.add({'_id': '2', 'name': 'Sakila', 'age': 15},
                    {'_id': '3', 'name': 'Jack', 'age': 15},
                    {'_id': '4', 'name': 'Clare', 'age': 37}).execute()

    def remove_from_collection(self):
        # Removing non-existing _id
        self.collection_obj.remove('_id = 1').execute()


    def alter_table_engine(self):
        # Altering table engine to rocksdb; Should raise an error
        try:
            command = "alter table {}.{} engine=rocksdb".format(self.schema_name, self.collection_name)
            sql = self.session.sql(command)
            sql.execute()
        except Exception as e:
            raise mysqlx.errors.OperationalError("Could not alter engine of table here!")
        else:
            return 0

    def alter_table_drop_column(self):
        # Dropping generated column
        print "Altering default collection to drop generated column"
        try:
            command = "alter table {}.{} drop column `_id`".format(self.schema_name, self.collection_name)
            sql = self.session.sql(command)
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def return_table_obj(self):
        # Returning Table object
        table = mysqlx.Table(self.schema, self.collection_name)
        return table

    def create_view_from_collection(self, view_name):
        # Creating view from collection
        print "Trying to create view based on MyRocks collection"
        try:
            command = "create view {}.{} as select * from {}.{}".format(self.schema_name, view_name, self.schema_name, self.collection_name)
            sql = self.session.sql(command)
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def select_from_view(self, view_name):
        # Running select; Should raise an error
        print "Trying to select from view [Should raise an OperationalError]"
        try:
            command = "select * from {}.{}".format(self.schema_name, view_name)
            sql = self.session.sql(command)
            sql.execute()
        except Exception as e:
            #raise mysqlx.errors.OperationalError("The JSON binary value contains invalid data")
            print e
        else:
            return 0
