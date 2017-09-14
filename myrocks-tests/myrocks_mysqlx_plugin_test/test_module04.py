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
        return_bulk_object.run_alter_storage_engine(schema_name="employees", table_name="salaries", engine="rocksdb") == 0
        # Disabling bulk load
        return_bulk_object.run_set_rocksdb_bulk_load(0)
        # Enabling bin log
        return_bulk_object.run_set_sql_log_bin(1)
