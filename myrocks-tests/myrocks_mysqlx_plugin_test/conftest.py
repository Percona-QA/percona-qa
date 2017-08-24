from myrocks_mysqlx_plugin.myrocks_mysqlx_plugin import MyXPlugin
import pytest
# schema_name = "generated_columns_test"
# collection_name = "my_collection"
plugin_obj = MyXPlugin("generated_columns_test", "my_collection")

@pytest.fixture(scope="module")
def return_plugin_obj(self):
    return plugin_obj
