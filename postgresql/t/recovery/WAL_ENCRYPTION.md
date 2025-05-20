## Enabling WAL Encryption for Test Cases

To run the test cases with Write-Ahead Logging (WAL) encryption enabled or disabled, you need to set the `WAL_ENCRYPTION` environment variable. When `WAL_ENCRYPTION` is set to `'on'`, all relevant tests will execute with WAL encryption enabled. If set to `'off'`, the tests will run without WAL encryption.

By default, WAL encryption is **off** unless the environment variable is explicitly set to `'on'`.  
For example, in Perl you can set the default as follows:

```perl
my $WAL_ENCRYPTION = $ENV{WAL_ENCRYPTION} // 'off';
```

You can enable WAL encryption in one of two ways:
1. **Globally:** Set the environment variable before running the test suite.
2. **Per Test Case:** Set the environment variable within each individual test case as needed.

**Example (Global):**
```sh
export WAL_ENCRYPTION=on   # Enables WAL encryption for all tests
export WAL_ENCRYPTION=off  # Disables WAL encryption for all tests
```

**Example (Per Test Case):**
Within a test script or framework, you can set the environment variable at the start of a test case:
```sh
WAL_ENCRYPTION=on <run your specific test here>
```