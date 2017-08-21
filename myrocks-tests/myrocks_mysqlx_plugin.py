# Connecting to MySQL and working with a Session
import mysqlx

mysqlx.ssl

# Connect to a dedicated MySQL server
session = mysqlx.get_session({
    'host': 'localhost',
    'port': 33060,
    'user': 'bakux',
    'password': 'Baku12345#',
    'ssl-mode': 'disabled'
})

schema = session.get_schema('generated_columns_test')

# Create 'my_collection' in schema
schema.create_collection('my_collection')

assert(True == collection.exists_in_database())

# Get 'my_collection' from schema
collection = schema.get_collection('my_collection')

# You can also add multiple documents at once
collection.add({'_id': '2', 'name': 'Sakila', 'age': 15},
            {'_id': '3', 'name': 'Jack', 'age': 15},
            {'_id': '4', 'name': 'Clare', 'age': 37}).execute()

collection.remove('_id = 1').execute()

assert(3 == collection.count())
