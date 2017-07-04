from pmm_stress_test_py import randomized_intances
import pytest

class TestPMMStress:
    """
    Tests for pmm strest test framework
    """

    def test_pmm_framework_add_client(self):
        """Checking return value from function"""
        print("\nIn test_pmm_framework_add_client()...")
        return_value = randomized_intances.pmm_framework_add_client("ps", 3)
        assert return_value == 0
