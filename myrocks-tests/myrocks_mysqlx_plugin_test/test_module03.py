# Created by Shahriyar Rzayev from Percona

from myrocks_mysqlx_plugin.lock_in_share_mode import MyXPluginLocks
import pytest

class TestLocks:
    '''
        Testing LOCK IN SHARE MODE
    '''

    @pytest.mark.usefixtures("return_lock_object1")
    def test_create_schema(self, return_lock_object1, schema_name="locks"):
        assert return_lock_object1.create_schema(schema_name) == "locks"

    @pytest.mark.usefixtures("return_lock_object1")
    def test_create_table(self, return_lock_object1, schema_name="locks", table_name="t1"):
        assert return_lock_object1.create_table(schema_name, table_name) == 0
