# Created by Shahriyar Rzayev from Percona

from myrocks_mysqlx_plugin.myrocks_mysqlx_plugin import MyXPlugin
from myrocks_mysqlx_plugin.lock_in_share_mode import MyXPluginLocks
import pytest
# schema_name = "generated_columns_test"
# collection_name = "my_collection"
plugin_obj = MyXPlugin("generated_columns_test", "my_collection")

@pytest.fixture()
def return_plugin_obj():
    return plugin_obj

lock_object1 = MyXPluginLocks()

@pytest.fixture()
def return_lock_object1():
    return lock_object1

lock_object2 = MyXPluginLocks()

@pytest.fixture()
def return_lock_object2():
    return lock_object2
