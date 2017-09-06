from myrocks_mysqlx_plugin import myrocks_mysqlsh
import pytest

class TestMySQLShell:

    def test_mysqlsh_db_get_collections(self):
        # Checking the length returned list here
        return_value = myrocks_mysqlsh.mysqlsh_db_get_collections('bakux', 'Baku12345', 33060)
        assert len(return_value) == 0
