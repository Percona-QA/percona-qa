# PGSM Test Framework

A Bash-based automated testing framework for Percona PostgreSQL Statistics Monitor (`pg_stat_monitor`).

The framework is designed to provide repeatable functional, sanity, regression, and release validation testing for PGSM. It creates an isolated PostgreSQL test environment, loads `pg_stat_monitor`, executes selected test suites, records results, and returns an appropriate exit code for local execution and CI systems such as Jenkins.

---

## Goals

The primary goals of this framework are:

* Provide automated testing for `pg_stat_monitor`.
* Support sanity, functional, regression, and release validation tests.
* Create an isolated PostgreSQL test environment automatically.
* Automatically configure `shared_preload_libraries`.
* Automatically create the `pg_stat_monitor` extension.
* Support execution of individual tests or complete suites.
* Make it easy to add new test cases.
* Generate machine-readable and human-readable test results.
* Return a non-zero exit code when tests fail.
* Support execution from Jenkins or other CI environments.
* Use a fixed runtime directory under `/tmp/pgsm_tests/`.
* Prevent multiple concurrent instances of the framework from running against the same runtime environment.

---

## Project Structure

```text
pgsm_tests/
│
├── run_tests.sh
├── README.md
│
├── config/
│   └── test_config.sh
│
├── lib/
│   ├── common.sh
│   ├── logging.sh
│   ├── assertions.sh
│   ├── postgres.sh
│   └── pgsm.sh
│
├── tests/
│   ├── sanity/
│   │   ├── PGSM-SANITY-001.sh
│   │   └── PGSM-SANITY-002.sh
│   │
│   ├── functional/
│   ├── regression/
│   └── release/
│
├── results/
│
└── logs/
```

---

# Components

## `run_tests.sh`

The main entry point for the framework.

Responsibilities include:

* Parsing command-line arguments.
* Loading framework libraries.
* Checking prerequisites.
* Creating result and log directories.
* Collecting environment information.
* Creating and starting the PostgreSQL test cluster.
* Loading `pg_stat_monitor`.
* Creating the extension.
* Discovering and selecting tests.
* Executing selected tests.
* Recording PASS and FAIL results.
* Printing the final test summary.
* Returning the appropriate process exit code.

---

## `config/test_config.sh`

Contains environment-specific configuration.

Typical configuration includes:

* PostgreSQL installation paths.
* PostgreSQL binaries.
* PostgreSQL port.
* Test database name.
* Runtime directory.
* Expected PGSM release version.
* PostgreSQL configuration options.

Example:

```bash
PGSM_EXPECTED_VERSION="2.4.0"
```

The expected version is used during release validation to verify that the version reported by the installed `pg_stat_monitor` extension matches the expected release version.

For example:

```text
Expected version: 2.4.1
Installed version: 2.4.0

Result: FAIL
```

---

## `lib/common.sh`

Contains generic framework utilities that are not PostgreSQL- or PGSM-specific.

Examples include:

* Command validation.
* File validation.
* Directory helpers.
* String helpers.
* Timestamp helpers.
* Input validation.
* Retry functionality.
* Safe cleanup helpers.

---

## `lib/logging.sh`

Provides centralized logging functions.

Typical log levels include:

```text
INFO
DEBUG
PASS
FAIL
SKIP
ERROR
```

Example:

```text
[INFO] Starting PostgreSQL
[PASS] pg_stat_monitor extension exists
[FAIL] PGSM version mismatch
[ERROR] PostgreSQL failed to start
```

Verbose logging can be enabled using:

```bash
./run_tests.sh --verbose
```

---

## `lib/assertions.sh`

Contains assertion helpers used by test cases.

Assertions are responsible for validating expected test results and returning success or failure.

Examples include:

```bash
assert_equal
assert_not_equal
assert_not_empty
assert_empty
assert_true
assert_false
assert_contains
```

A failed assertion must return a non-zero status.

Test cases should propagate assertion failures using:

```bash
assert_equal \
    "PGSM version" \
    "${expected_version}" \
    "${actual_version}" || return 1
```

---

## `lib/postgres.sh`

Provides PostgreSQL lifecycle and SQL execution helpers.

Functions include:

```text
postgres_init()
postgres_start()
postgres_stop()
postgres_restart()
postgres_reload()
postgres_is_running()
postgres_version()
postgres_create_database()
postgres_drop_database()
execute_sql()
execute_sql_file()
```

The framework automatically creates and manages a dedicated PostgreSQL test cluster.

The runtime environment is located under:

```text
/tmp/pgsm_tests/
```

Typical structure:

```text
/tmp/pgsm_tests/
├── data/
├── socket/
└── postgresql.log
```

---

## `lib/pgsm.sh`

Contains PGSM-specific helpers.

Responsibilities include:

* Verifying that `pg_stat_monitor` is available.
* Checking that PGSM is loaded using `shared_preload_libraries`.
* Creating the extension.
* Dropping the extension.
* Reading the installed PGSM version.
* Performing PGSM-specific operations required by tests.

---

# Running Tests

## Default Test Run

The default execution mode currently runs the sanity suite.

```bash
./run_tests.sh
```

---

## List Available Tests

```bash
./run_tests.sh --list
```

Example output:

```text
TEST ID                   TEST NAME                                      SUITE
------------------------- --------------------------------------------- --------------------
PGSM-SANITY-001           Verify pg_stat_monitor installation and version sanity
PGSM-SANITY-002           Verify all pg_stat_monitor GUCs                sanity
```

---

## Run a Test Suite

```bash
./run_tests.sh --suite sanity
```

Future suites may include:

```bash
./run_tests.sh --suite functional
./run_tests.sh --suite regression
./run_tests.sh --suite release
```

---

## Run a Single Test

Tests are selected using the test ID.

```bash
./run_tests.sh --test PGSM-SANITY-001
```

Do not include the `.sh` extension unless the framework is specifically designed to support filename-based selection.

Correct:

```bash
./run_tests.sh --test PGSM-SANITY-001
```

Incorrect:

```bash
./run_tests.sh --test PGSM-SANITY-001.sh
```

---

## Run Release Validation

```bash
./run_tests.sh --release
```

Release validation should include the minimum set of tests required before a new PGSM version is released.

The release workflow should verify:

* PostgreSQL starts successfully.
* `pg_stat_monitor` is present in `shared_preload_libraries`.
* The extension is available.
* The extension can be created.
* The installed PGSM version matches `PGSM_EXPECTED_VERSION`.
* Core PGSM functionality works correctly.
* All required release tests pass.

---

## Run All Tests

```bash
./run_tests.sh --all
```

---

## Enable Verbose Logging

```bash
./run_tests.sh --all --verbose
```

---

# Test Structure

Each test is a Bash script.

Example:

```bash
#!/usr/bin/bash

TEST_ID="PGSM-SANITY-001"
TEST_NAME="Verify pg_stat_monitor installation and version"
TEST_SUITE="sanity"

test_setup()
{
    return 0
}

test_body()
{
    # Test implementation.

    return 0
}

test_cleanup()
{
    return 0
}
```

The framework supports three optional test phases.

## `test_setup()`

Used to prepare the test environment.

Examples:

* Create tables.
* Create databases.
* Set GUC values.
* Insert test data.

---

## `test_body()`

Contains the actual test logic.

A test must define:

```bash
test_body()
```

Assertion failures should propagate correctly:

```bash
assert_equal \
    "Expected value" \
    "${expected}" \
    "${actual}" || return 1
```

---

## `test_cleanup()`

Used to clean up resources created by the test.

Examples:

* Drop tables.
* Drop databases.
* Reset GUCs.
* Remove temporary test data.

The framework attempts to preserve the result of `test_body()` even when cleanup is executed.

---

# Test Naming Convention

Test files should use a consistent naming format:

```text
PGSM-<SUITE>-<NUMBER>.sh
```

Examples:

```text
PGSM-SANITY-001.sh
PGSM-SANITY-002.sh
PGSM-FUNCTIONAL-001.sh
PGSM-REGRESSION-001.sh
PGSM-RELEASE-001.sh
```

Each test must define:

```bash
TEST_ID
TEST_NAME
```

The suite may be explicitly defined:

```bash
TEST_SUITE="sanity"
```

If `TEST_SUITE` is not defined, the framework may derive the suite from the test directory.

---

# Results

Each execution creates a timestamped result directory.

Example:

```text
results/
└── 2026-09-09_18-41-27/
    ├── results.csv
    ├── summary.txt
    ├── failures.txt
    └── environment.txt
```

## `results.csv`

Contains one row per test.

Example:

```text
test_id,test_name,suite,status,duration_seconds
PGSM-SANITY-001,"Verify pg_stat_monitor installation and version",sanity,PASS,1
PGSM-SANITY-002,"Verify all pg_stat_monitor GUCs",sanity,PASS,2
```

---

## `summary.txt`

Contains the overall execution summary.

Example:

```text
Total tests : 2
Passed      : 2
Failed      : 0
Skipped     : 0
Duration    : 5s
```

---

## `failures.txt`

Contains failed tests.

Example:

```text
PGSM-SANITY-002 - Verify all pg_stat_monitor GUCs
```

---

## `environment.txt`

Contains information about the execution environment.

Typical information includes:

* Date.
* Hostname.
* Operating system.
* PostgreSQL version.
* Framework configuration.

---

# Logs

Each test run should have a timestamped framework log directory.

Example:

```text
logs/
└── 2026-09-09_18-41-27/
    └── framework.log
```

PostgreSQL server logs are stored in the runtime directory:

```text
/tmp/pgsm_tests/postgresql.log
```

When a PostgreSQL startup or runtime failure occurs, this file should be checked first.

---

# Failure Handling

The framework is designed so that assertion failures propagate through the following layers:

```text
assertion
    ↓
test_body()
    ↓
run_test()
    ↓
run_tests()
    ↓
run_tests.sh
```

A failed assertion should cause:

```text
Test status: FAIL
Framework exit code: 1
```

The framework should continue executing remaining selected tests after an individual test failure and report the complete summary at the end.

This behavior is important for CI systems such as Jenkins.

---

# Exit Codes

The framework uses the following exit codes:

```text
0 - All selected tests passed.
1 - One or more tests failed or a framework error occurred.
2 - Invalid command-line usage.
```

---

# Runtime Directory

The framework uses a fixed runtime directory:

```text
/tmp/pgsm_tests/
```

This directory is intended for temporary PostgreSQL test execution.

The framework may contain:

```text
/tmp/pgsm_tests/
├── data/
├── socket/
└── postgresql.log
```

The directory is cleaned and recreated as required by the framework.

Only one instance of the framework should operate on this runtime directory at a time.

This design is suitable for:

* Dedicated Jenkins workers.
* Ephemeral AWS test instances.
* Local development environments.

---

# Release Validation

Before validating a new PGSM release, configure the expected version:

```bash
PGSM_EXPECTED_VERSION="2.4.1"
```

Then execute the release suite:

```bash
./run_tests.sh --release
```

A version mismatch must fail the release validation.

Example:

```text
Expected version: 2.4.1
Installed version: 2.4.0

[FAIL] pg_stat_monitor version matches expected release version
```

The framework should return:

```text
Exit code: 1
```

This allows Jenkins or another CI system to correctly mark the release validation job as failed.

---

# Adding a New Test

1. Select the appropriate suite.

For example:

```text
tests/functional/
```

2. Create a new test file:

```text
PGSM-FUNCTIONAL-001.sh
```

3. Define the metadata:

```bash
TEST_ID="PGSM-FUNCTIONAL-001"
TEST_NAME="Verify basic query tracking"
TEST_SUITE="functional"
```

4. Implement `test_body()`.

5. Use assertions from `lib/assertions.sh`.

6. Ensure assertion failures propagate:

```bash
assert_equal \
    "Query count" \
    "1" \
    "${query_count}" || return 1
```

7. Run the test:

```bash
./run_tests.sh --test PGSM-FUNCTIONAL-001
```

---

# Current Status

The framework currently provides:

* PostgreSQL test cluster initialization.
* PostgreSQL start and stop management.
* Dedicated runtime environment under `/tmp/pgsm_tests/`.
* PGSM loading through `shared_preload_libraries`.
* Automatic `CREATE EXTENSION pg_stat_monitor`.
* Test discovery.
* Test selection by suite or test ID.
* Individual test execution.
* PASS and FAIL tracking.
* Failure propagation.
* Test result CSV generation.
* Execution summaries.
* Environment information collection.
* Basic sanity testing.
* PGSM version validation.
* PGSM GUC validation.

Future iterations will add additional functional, regression, edge-case, compatibility, and release validation scenarios.

