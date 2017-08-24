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

        self.schema = session.get_schema(self.schema_name)
        self.schema.create_collection(self.collection_name)
        self.collection_obj = self.schema.get_collection(self.collection_name)

    # def create_collection(self, collection_name):
    #     # Create 'my_collection' in schema
    #     print "Creating collection"
    #     self.schema.create_collection(collection_name)
    #
    # def return_collection_obj(self, collection_name):
    #     collection_obj = schema.get_collection(collection_name)
    #     return collection_obj

    # # Get 'my_collection' from schema
    #
    # print "Checking assert(True == collection.exists_in_database())"
    # assert(True == collection.exists_in_database())

    def insert_into_collection(self):
        # You can also add multiple documents at once
        print "Inserting 3 rows into collection"
        self.collection_obj.add({'_id': '2', 'name': 'Sakila', 'age': 15},
                    {'_id': '3', 'name': 'Jack', 'age': 15},
                    {'_id': '4', 'name': 'Clare', 'age': 37}).execute()

    def remove_from_collection(self):
        self.collection_obj.remove('_id = 1').execute()

# print "Checking assert(3 == collection.count())"
# assert(3 == collection.count())
    def alter_table_engine(self):
        print "Altering default collection engine from InnoDB to MyRocks [Should raise an OperationalError]"
        try:
            sql = self.session.sql("alter table generated_columns_test.my_collection engine=rocksdb")
            sql.execute()
        except Exception as e:
            raise mysqlx.errors.OperationalError("Could not alter engine of table here!")
        else:
            return 0

    def alter_table_drop_column(self):
        print "Altering default collection to drop generated column"
        try:
            sql = self.session.sql("alter table generated_columns_test.my_collection drop column `_id`")
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    # print "Altering default collection engine from InnoDB to MyRocks [Should NOT raise an OperationalError]"
    # try:
    #     sql = session.sql("alter table generated_columns_test.my_collection engine=rocksdb")
    #     sql.execute()
    # except mysqlx.errors.OperationalError as e:
    #     print e
    def return_table_obj(self, dbname, collection_name):
        print "Trying to access collection using mysqlx.Table"
        table = mysqlx.Table(dbname, collection_name)
        return table
# print "Checking assert(True == table.exists_in_database())"
# assert(True == table.exists_in_database())
#
# print "Checking assert(3 == table.count())"
# assert(3 == table.count())
#
# print "Checking assert('my_collection' == table.get_name())"
# assert("my_collection" == table.get_name())
#
# print "Checking assert('generated_columns_test' == table.get_schema())"
# assert("generated_columns_test" == table.get_schema().get_name())
#
# print "Checking assert(False == table.is_view())"
# assert(False == table.is_view())
    def create_view_from_collection(self):
        print "Trying to create view based on MyRocks collection"
        try:
            sql = self.session.sql("create view generated_columns_test.my_collection_view as select * from generated_columns_test.my_collection")
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0

    def select_from_view(self):
        print "Trying to select from view [Should raise an OperationalError]"
        try:
            sql = self.session.sql("select * from generated_columns_test.my_collection_view")
            sql.execute()
        except Exception as e:
            raise
        else:
            return 0
