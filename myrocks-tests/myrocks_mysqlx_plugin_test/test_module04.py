# Created by Shahriyar Rzayev from Percona
# Test module for testing rocksdb_bulk_load.py

import pytest

class TestBulk:
    '''
        Testing ROCKSDB BULK LOAD
    '''

    @pytest.mark.usefixtures("return_bulk_object")
    def test_alter_table_engine_bulk(self, return_bulk_object):
        # Altering table engine to rocksdb using bulk load from large myisam table
        # # Starting transaction
        # return_bulk_object.start_transaction()
        # Disabling bin log
        return_bulk_object.run_set_sql_log_bin(0)
        # Dropping foreign key
        return_bulk_object.run_alter_drop_foreign_key(schema_name="employees", table_name="salaries")
        # Altering table engine to myisam from already existing innodb table
        return_bulk_object.run_alter_storage_engine(schema_name="employees", table_name="salaries", engine="myisam")
        # Enabling bulk load
        return_bulk_object.run_set_rocksdb_bulk_load(1)
        # Altering table engine to rocksdb
        value = return_bulk_object.run_alter_storage_engine(schema_name="employees", table_name="salaries", engine="rocksdb")
        # Disabling bulk load
        return_bulk_object.run_set_rocksdb_bulk_load(0)
        # Enabling bin log
        return_bulk_object.run_set_sql_log_bin(1)
        assert value == 0

    @pytest.mark.usefixtures("return_bulk_object")
    def test_select_enabled_bulk_load(self, return_bulk_object):
        # Enabling bulk load
        return_bulk_object.run_set_rocksdb_bulk_load(1)

        # Creating table
        return_bulk_object.run_create_table(schema_name="employees", table_name="salaries2",
                                            from_schema_name="employees", from_table_name="salaries")

        # Inserting data into new table
        return_bulk_object.run_insert_statement(schema_name="employees", table_name="salaries2",
                                                emp_no=11111, from_date="1998-12-24")

        return_bulk_object.run_insert_statement(schema_name="employees", table_name="salaries2",
                                                emp_no=11110, from_date="1989-11-13")
        # Selecting the count from table
        obj = return_bulk_object.run_select_statement(schema_name="employees", table_name="salaries2")
        for i in obj:
            assert i == 0
