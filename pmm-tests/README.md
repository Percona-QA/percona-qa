# Welcome to PMM testing land.

It is integrated into pmm-framework.sh
  > Please call pmm-framework.sh from where PS tarball downloaded.


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
 --run-tests               Run automated bats tests
```

The options are quite clear.
The interesting part for us maybe `--run-tests` option. It will start the PS instance on /tmp and will run all tests against it.

```

[sh@centos7-base ~]$ ./percona-qa/pmm-tests/pmm-framework.sh --run-tests

Configuring Percona Server daemon for pmm test run.


Removing old Percona Server installation for pmm test run.

Dummy Percona Server started ok. Client:
/home/sh/Percona-Server-5.7.16-10-Linux.x86_64.ssl101/bin/mysql -uroot -S/tmp/pmm_ps_data/mysql.sock
[sudo] password for sh:
 - run pmm-admin under regular(non-root) user privileges (skipped: Skipping this test, because you are running under root)
 ✓ run pmm-admin under root privileges
 ✓ run pmm-admin without any arguments
 ✓ run pmm-admin help
 ✓ run pmm-admin -h
 ✓ run pmm-admin with wrong option
 ✓ run pmm-admin ping
 ✓ run pmm-admin check-network
 ✓ run pmm-admin list
 ✓ run pmm-admin add linux:metrics
 ✓ run pmm-admin add linux:metrics again
 ✓ run pmm-admin remove linux:metrics
 ✓ run pmm-admin remove linux:metrics again
 ✓ run pmm-admin add linux:metrics with given name
 ✓ run pmm-admin add linux:metrics with given name again
 ✓ run pmm-admin remove linux:metrics with given name
 ✓ run pmm-admin remove linux:metrics with given name again
 ✓ run pmm-admin add mysql:metrics
 ✓ run pmm-admin add mysql:metrics again
 ✓ run pmm-admin remove mysql:metrics
 ✓ run pmm-admin remove mysql:metrics again
 ✓ run pmm-admin add mysql:metrics with given name
 ✓ run pmm-admin add mysql:metrics with given name again
 ✓ run pmm-admin remove mysql:metrics with given name
 ✓ run pmm-admin remove mysql:metrics with given name again
 ✓ run pmm-admin add mysql:queries
 ✓ run pmm-admin add mysql:queries again
 ✓ run pmm-admin remove mysql:queries
 ✓ run pmm-admin remove mysql:queries again
 ✓ run pmm-admin add mysql:queries with given name
 ✓ run pmm-admin add mysql:queries with given name again
 ✓ run pmm-admin remove mysql:queries with given name
 ✓ run pmm-admin remove mysql:queries with given name again
 ✓ run pmm-admin add mysql
 ✓ run pmm-admin add mysql again
 ✓ run pmm-admin remove mysql
 ✓ run pmm-admin remove mysql again
 ✓ run pmm-admin add mysql with given name
 ✓ run pmm-admin add mysql with given name again
 ✓ run pmm-admin remove mysql with given name
 ✓ run pmm-admin remove mysql with given name again
 ✓ run pmm-admin add mysql with --create-user
 ✓ run pmm-admin show-passwords to check whether new MySQL user password=pmmpass123 is there?
 ✓ run pmm-admin add mysql with given name(It must use new created 'pmm' user for adding services)
 ✓ run pmm-admin add mysql with --create-user and --force option(to force create/update user)
 ✓ run pmm-admin show-passwords to check whether new MySQL user password=pmmpass345 is there?
 ✓ run pmm-admin add mysql --query-source=perfschema
 ✓ run pmm-admin list to check if query-source perfschema is enabled
 ✓ run pmm-admin add mysql --query-source=slowlog
 ✓ run pmm-admin list to check if query-source slowlog is enabled
 ✓ run pmm-admin rm --all
 ✓ run pmm-admin list to check for available services
 ✓ run pmm-admin info
 ✓ run pmm-admin show-passwords
 ✓ run pmm-admin --version
 ✓ run pmm-admin start without service type
 ✓ run pmm-admin stop without service type
 ✓ run pmm-admin restart without service type
 ✓ run pmm-admin purge without service type
 ✓ run pmm-admin config without parameters

60 tests, 0 failures, 1 skipped


```
