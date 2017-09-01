# Created by Shahriyar Rzayev from Percona

from myrocks_mysqlx_plugin.lock_in_share_mode import MyXPluginLocks
from mysqlx.errors import OperationalError
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

    @pytest.mark.usefixtures("return_lock_object1")
    def test_insert_dummy_data_into_table(self, return_lock_object1,
                                                schema_name="locks",
                                                table_name="t1",
                                                value_id=994,
                                                value_name="Baku"):
        assert return_lock_object1.insert_dummy_data_into_table(schema_name, table_name, value_id, value_name) == 0

    @pytest.mark.usefixtures("return_lock_object1")
    def test_run_lock_in_share_select_gap_lock(self, return_lock_object1, schema_name="locks", table_name="t1", value_id=994):
        return_lock_object1.start_transaction()
        with pytest.raises(OperationalError) as er:
            return_lock_object1.run_lock_in_share_select(schema_name, table_name, value_id)
        print er

    @pytest.mark.usefixtures("return_lock_object2")
    def test_run_update_statement_gap_lock(self, return_lock_object2,
                                        schema_name="locks",
                                        table_name="t1",
                                        value_id=994,
                                        value_name="Azerbaijan"):
        return_lock_object2.start_transaction()
        with pytest.raises(OperationalError) as er:
            return_lock_object2.run_update_statement(schema_name, table_name, value_id, value_name)
        print er

    @pytest.mark.usefixtures("return_lock_object1")
    def test_run_for_update_gap_lock(self, return_lock_object1, schema_name="locks", table_name="t1", value_id=994):
        return_lock_object1.start_transaction()
        with pytest.raises(OperationalError) as er:
            return_lock_object1.run_for_update(schema_name, table_name, value_id)
        print er
        return_lock_object1.commit_transaction()

    @pytest.mark.usefixtures("return_lock_object2")
    def test_run_for_update2_gap_lock(self, return_lock_object2, schema_name="locks", table_name="t1", value_id=994):
        return_lock_object2.start_transaction()
        with pytest.raises(OperationalError) as er:
            return_lock_object2.run_for_update(schema_name, table_name, value_id)
        print er
        return_lock_object2.commit_transaction()

    @pytest.mark.usefixtures("return_lock_object1")
    def test_run_alter_add_primary_key(self, return_lock_object1, schema_name="locks", table_name="t1"):
        assert return_lock_object1.run_alter_add_primary_key(schema_name, table_name) == 0


    @pytest.mark.usefixtures("return_lock_object1")
    def test_run_lock_in_share_select(self, return_lock_object1, schema_name="locks", table_name="t1", value_id=994):
        return_lock_object1.start_transaction()
        assert return_lock_object1.run_lock_in_share_select(schema_name, table_name, value_id) == 0


    @pytest.mark.usefixtures("return_lock_object2")
    def test_run_update_statement(self, return_lock_object2,
                                        schema_name="locks",
                                        table_name="t1",
                                        value_id=994,
                                        value_name="Azerbaijan"):
        return_lock_object2.start_transaction()
        assert return_lock_object2.run_update_statement(schema_name, table_name, value_id, value_name) == 0


    @pytest.mark.usefixtures("return_lock_object1")
    def test_run_for_update(self, return_lock_object1, schema_name="locks", table_name="t1", value_id=994):
        return_lock_object1.start_transaction()
        assert return_lock_object1.run_for_update(schema_name, table_name, value_id) == 0


    @pytest.mark.usefixtures("return_lock_object2")
    def test_run_for_update2(self, return_lock_object2, schema_name="locks", table_name="t1", value_id=994):
        return_lock_object2.start_transaction()
        with pytest.raises(OperationalError) as er:
            return_lock_object2.run_for_update(schema_name, table_name, value_id)
        print er
