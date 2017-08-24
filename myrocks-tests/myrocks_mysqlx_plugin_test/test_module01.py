import pytest

@pytest.mark.usefixtures("return_plugin_obj")
class TestXPlugin:
    """
    Tests for XPlugin + MyRocks
    """

    def test_check_if_collection_exists(self, return_plugin_obj):
        assert return_plugin_obj.collection_obj.exists_in_database() == True

    def test_check_collection_count(self, return_plugin_obj):
        assert return_plugin_obj.collection_obj.count() == 3

    def test_alter_table_engine_raises(self, return_plugin_obj):
        # Should raise error here
        with pytest.raises(OperationalError) as er:
            return_plugin_obj.alter_table_engine()
        print er

    def test_alter_table_drop_column(self, return_plugin_obj):
        return_value = return_plugin_obj.alter_table_drop_column()
        assert return_value == 0

    def test_alter_table_engine(self, return_plugin_obj):
        return_value = return_plugin_obj.alter_table_engine()
        assert return_value == 0

    def helper_function(self, return_plugin_obj):
        table_obj = return_plugin_obj.return_table_obj()
        return table_obj

    def test_check_if_table_exists(self):
        assert self.helper_function().exists_in_database() == True

    def test_check_table_count(self):
        assert self.helper_function().count() == 3

    def test_check_table_name(self):
        assert self.helper_function().get_name() == "my_collection"

    def test_check_schema_name(self):
        assert self.helper_function().get_schema().get_name() == "generated_columns_test"

    def test_check_if_table_is_view(self):
        assert self.helper_function().is_view() == False

    def test_create_view_from_collection(self):
        return_value = return_plugin_obj.create_view_from_collection()
