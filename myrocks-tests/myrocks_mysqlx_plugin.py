# Connecting to MySQL and working with a Session
import mysqlx

# Connect to a dedicated MySQL server
session = mysqlx.get_session({
    'host': 'localhost',
    'port': 33060,
    'user': 'bakux',
    'password': 'Baku12345',
    'ssl-mode': mysqlx.SSLMode.DISABLED
})

schema = session.get_schema('generated_columns_test')

# Create 'my_collection' in schema
print "Creating collection"
schema.create_collection('my_collection')

# Get 'my_collection' from schema
collection = schema.get_collection('my_collection')
print "Checking assert(True == collection.exists_in_database())"
assert(True == collection.exists_in_database())

# You can also add multiple documents at once
print "Inserting 3 rows into collection"
collection.add({'_id': '2', 'name': 'Sakila', 'age': 15},
            {'_id': '3', 'name': 'Jack', 'age': 15},
            {'_id': '4', 'name': 'Clare', 'age': 37}).execute()

collection.remove('_id = 1').execute()
print "Checking assert(3 == collection.count())"
assert(3 == collection.count())

print "Altering default collection engine from InnoDB to MyRocks [Should raise an OperationalError]"
try:
    sql = session.sql("alter table generated_columns_test.my_collection engine=rocksdb")
    sql.execute()
except mysqlx.errors.OperationalError as e:
    print e


print "Altering default collection to drop generated column"
try:
    sql = session.sql("alter table generated_columns_test.my_collection drop column `_id`")
    sql.execute()
except Exception as e:
    raise

print "Altering default collection engine from InnoDB to MyRocks [Should NOT raise an OperationalError]"
try:
    sql = session.sql("alter table generated_columns_test.my_collection engine=rocksdb")
    sql.execute()
except mysqlx.errors.OperationalError as e:
    print e

print "Trying to access collection using mysqlx.Table"
table = mysqlx.Table(schema, collection)
assert(True == table.exists_in_database())
