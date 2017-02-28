# Welcome to PMM testing land.

It is integrated into pmm-testsuite.bats
  > Please call from where PS tarball downloaded.

The project structure:
```

generic-tests.bats -> Generic PMM client tests/
linux-metrics.bats -> linux:metrics tests
pmm-framework.sh   -> Executable for creating environment
pmm-testsuite.bats -> The test suite bats file
ps-specific-tests.bats -> PS specific tests

```


Sample run for PS:

```

[sh@centos7-base ~]$ instance_t="ps" instance_c="2" bats percona-qa/pmm-tests/pmm-testsuite.bats
✓ Wipe clients
✓ Adding clients
✓ Running generic tests
✓ Running PS specific tests
✓ Wipe clients
5 tests, 0 failures

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
