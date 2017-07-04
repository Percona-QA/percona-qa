from pmm_stress_test_py import randomized_instances
import pytest

class TestPMMStress:
    """
    Tests for pmm strest test framework
    """

    def test_pmm_framework_add_client(self):
        """Checking return value from function"""
        print("\nIn test_pmm_framework_add_client()...")
        return_value = randomized_instances.pmm_framework_add_client("ps", 3)
        assert return_value == 0

    def test_getting_instance_socket(self):
        """Checking return value type and value from function"""
        return_value = randomized_instances.getting_instance_socket()
        assert isinstance(return_value, list)
        assert len(return_value) > 0

    def test_pmm_framework_wipe_client(self):
        """Checking return value from function"""
        print("\nIn test_pmm_framework_wipe_client()...")
        return_value = randomized_instances.pmm_framework_wipe_client()
        assert return_value == 0
