from pmm_stress_test_py import randomized_instances
import pytest

class TestPMMStress:
    """
    Tests for pmm strest test framework
    """

    def test_pmm_framework_add_client(self):
        """Checking return value from function"""
        print("\nIn test_pmm_framework_add_client()...")
        return_value = randomized_instances.pmm_framework_add_client("ps", 2)
        assert return_value == 0

    def test_getting_instance_socket(self):
        """Checking return value type and value from function"""
        return_value = randomized_instances.getting_instance_socket()
        print(return_value)
        assert isinstance(return_value, list)
        assert len(return_value) > 0

    def helper_function(self, count):
        """Function for calling adding_instances()"""
        socks = randomized_instances.getting_instance_socket()
        try:
            for sock in socks:
                for i in range(count):
                    randomized_instances.adding_instances(sock, threads=0)
        except Exception as e:
            print(e)
        else:
            return 0

    def test_adding_instances(self):
        """Checking for return value from function"""
        return_value = self.helper_function(1)
        assert return_value == 0

    def test_create_db(self):
        """Checking for return value from function"""
        return_value = randomized_instances.create_db(10, "ps")
        assert return_value == 0

    def test_create_table(self):
        """Checking for return value from function"""
        return_value = randomized_instances.create_table(10, "ps")
        assert return_value == 0

    def test_run_sleep_query(self):
        """Checking for return value from function"""
        return_value = randomized_instances.run_sleep_query(20, "ps", 10)
        assert return_value == 0

    def test_create_unique_query(self):
        """Checking for return value from function"""
        return_value = randomized_instances.create_unique_query(10, "ps")
        assert return_value == 0

    def test_insert_blob(self):
        """Checking for return value from function"""
        return_value = randomized_instances.insert_blob(2, "ps")
        assert return_value == 0

    def test_insert_longtext(self):
        """Checking for return value from function"""
        return_value = randomized_instances.insert_longtext('2 10000', "ps")
        assert return_value == 0

    def test_pmm_framework_wipe_client(self):
        """Checking return value from function"""
        print("\nIn test_pmm_framework_wipe_client()...")
        return_value = randomized_instances.pmm_framework_wipe_client()
        assert return_value == 0
