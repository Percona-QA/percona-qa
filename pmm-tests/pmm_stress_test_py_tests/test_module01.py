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

    def test_pmm_framework_wipe_client(self):
        """Checking return value from function"""
        pytest.skip("Skipping for test purposes!")
        print("\nIn test_pmm_framework_wipe_client()...")
        return_value = randomized_instances.pmm_framework_wipe_client()
        assert return_value == 0
