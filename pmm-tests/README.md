# Welcome to PMM testing land.

It is integrated into pmm-testsuite.bats
  > Please call from where PS tarball downloaded.

The project structure:
```

generic-tests.bats      -> Generic PMM client tests/
linux-metrics.bats      -> linux:metrics tests
pmm-framework.sh        -> Executable for creating environment
mongodb-tests.bats      -> MongoDB specific tests
pmm-testsuite.bats      -> The test suite bats file
pmm-testsuite.sh      -> The workaround for issue #80, it will be used in jenkins
proxysql-tests.bats     -> proxysql:metrics tests
ps-specific-tests.bats  -> PS specific tests
pxc-specific-tests.bats -> PXC specific tests


```

Sample run for pmm-testsuite.sh:

Available options:
```
instance_t -> instance type
instance_c -> instance count
tap -> adding --tap option
stress -> enabling stress test
table_c -> the table count for stress test
table_size -> the table size to prepare using sysbench
pmm_docker_memory -> the option to enable test for --memory option
pmm_server_memory -> the option to enable test for -e METRICS_MEMORY
```

Sample run for memory tests:

Running -e METRICS_MEMORY test:
```
$ instance_t="pxc" instance_c="1" tap=1 pmm_server_memory=1 bash ~/percona-qa/pmm-tests/pmm-testsuite.sh
```

Running --memory test:
```
$ instance_t="pxc" instance_c="1" tap=1 pmm_docker_memory=1 bash ~/percona-qa/pmm-tests/pmm-testsuite.sh
```

> NOTE: If there is no options passed the default memory checker will run to test.

Running stress test, with 100 tables, with --tap option, for 3 ps instances:
```
$ instance_t="ps" instance_c="3" tap=1 stress=1 table_c=100 bash ~/percona-qa/pmm-tests/pmm-testsuite.sh
```

Running with --tap option, for 3 ps instances (no stress test):
```
$ instance_t="ps" instance_c="3" tap=1 bash ~/percona-qa/pmm-tests/pmm-testsuite.sh
```

Running with --tap option, for 3 ps instances to populate tables using sysbench(see table_size option).
It will create 1 table and populate it with 100000 rows for each 3 ps instance.
```
$ instance_t="ps" instance_c="3" tap=1 stress=1 table_c=1 table_size=100000 bash ~/percona-qa/pmm-tests/pmm-testsuite.sh
```


Sample run for PXC:

```

$ instance_t="pxc" instance_c="3" bats ./percona-qa/pmm-tests/pmm-testsuite.bats
 ✓ Wipe clients
 ✓ Adding clients
 ✓ Running linux metrics tests
 ✓ Running generic tests
 - Running MongoDB specific tests (skipped: Skipping MongoDB specific tests! )
 - Running PS specific tests (skipped: Skipping PS specific tests! )
 ✓ Running PXC specific tests
 ✓ Running ProxySQL tests
 ✓ Wipe clients

9 tests, 0 failures, 2 skipped

```

Sample run for Mongo:

```

$ instance_t="mo" instance_c="3" bats ./percona-qa/pmm-tests/pmm-testsuite.bats
 ✓ Wipe clients
 ✓ Adding clients
 - Running linux metrics tests (skipped: Skipping this test)
 ✓ Running generic tests
 ✓ Running MongoDB specific tests
 - Running PS specific tests (skipped: Skipping PS specific tests! )
 - Running PXC specific tests (skipped: Skipping PXC specific tests! )
 - Running ProxySQL tests (skipped: Skipping ProxySQL specific tests!)
 ✓ Wipe clients

9 tests, 0 failures, 4 skipped

```

Sample run for PS:

```
$ instance_t="ps" instance_c="3" bats ./percona-qa/pmm-tests/pmm-testsuite.bats
 ✓ Wipe clients
 ✓ Adding clients
 ✓ Running linux metrics tests
 ✓ Running generic tests
 - Running MongoDB specific tests (skipped: Skipping MongoDB specific tests! )
 ✓ Running PS specific tests
 - Running PXC specific tests (skipped: Skipping PXC specific tests! )
 - Running ProxySQL tests (skipped: Skipping ProxySQL specific tests!)
 ✓ Wipe clients

9 tests, 0 failures, 3 skipped

```

Sample stress test run(creating 10 tables with each added instance):

```
$ instance_t="ps" instance_c="3" stress=1 table_c=10  bats  ../percona-qa/pmm-tests/pmm-testsuite.bats
 ✓ Wipe clients
 ✓ Adding clients
 ✓ Running linux metrics tests
 ✓ Running generic tests
 ✓ WARN: Running stress tests
 - Running MongoDB specific tests (skipped: Skipping MongoDB specific tests! )
 ✓ Running PS specific tests
 - Running PXC specific tests (skipped: Skipping PXC specific tests! )
 - Running ProxySQL tests (skipped: Skipping ProxySQL specific tests!)
 ✓ Wipe clients

10 tests, 0 failures, 3 skipped
```

pmm-framework usage:


```
[sh@centos7-base ~]$ ./percona-qa/pmm-tests/pmm-framework.sh --help
Usage: [ options ]
Options:
 --setup                   This will setup and configure a PMM server
 --addclient=ps,2          Add Percona (ps), MySQL (ms), MariaDB (md), and/or mongodb (mo) pmm-clients to the currently live PMM server (as setup by --setup)
                           You can add multiple client instances simultaneously. eg : --addclient=ps,2  --addclient=ms,2 --addclient=md,2 --addclient=mo,2
 --list                    List all client information as obtained from pmm-admin
 --wipe-clients            This will stop all client instances and remove all clients from pmm-admin
 --wipe-server             This will stop pmm-server container and remove all pmm containers
 --wipe                    This will wipe all pmm configuration
 --dev                     When this option is specified, PMM framework will use the latest PMM development version. Otherwise, the latest 1.0.x version is used
 --pmm-server-username     User name to access the PMM Server web interface
 --pmm-server-password     Password to access the PMM Server web interface
```

The options are quite clear.
