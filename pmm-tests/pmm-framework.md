__PMM Framework__

This script enables one to quickly setup a Percona Monitoring and Management environment. One can setup a PMM server and quickly add multiple clients. 

__PMM Framework usage info__

```
Usage: [ options ]
Options:
 --setup                          This will setup and configure a PMM server
 --addclient=ps,2                 Add Percona (ps), MySQL (ms), MariaDB (md), Percona XtraDB Cluster (pxc), and/or mongodb (mo) pmm-clients to the currently live PMM server (as setup by --setup)
                                  You can add multiple client instances simultaneously. eg : --addclient=ps,2  --addclient=ms,2 --addclient=md,2 --addclient=mo,2 --addclient=pxc,3
 --download                       This will help us to download pmm client binary tar balls
 --ps-version                     Pass Percona Server version info
 --ms-version                     Pass MySQL Server version info
 --md-version                     Pass MariaDB Server version info
 --pxc-version                    Pass Percona XtraDB Cluster version info
 --mo-version                     Pass MongoDB Server version info
 --mongo-with-rocksdb             This will start mongodb with rocksdb engine
 --replcount                      You can configure multiple mongodb replica sets with this oprion
 --with-replica                   This will configure mongodb replica setup
 --with-shrading                  This will configure mongodb shrading setup
 --add-docker-client              Add docker pmm-clients with percona server to the currently live PMM server
 --list                           List all client information as obtained from pmm-admin
 --wipe-clients                   This will stop all client instances and remove all clients from pmm-admin
 --wipe-docker-clients            This will stop all docker client instances and remove all clients from docker container
 --wipe-server                    This will stop pmm-server container and remove all pmm containers
 --wipe                           This will wipe all pmm configuration
 --dev                            When this option is specified, PMM framework will use the latest PMM development version. Otherwise, the latest 1.0.x version is used
 --pmm-server-username            User name to access the PMM Server web interface
 --pmm-server-password            Password to access the PMM Server web interface
 --pmm-server=[docker|ami|ova]    Choose PMM server appliance, default pmm server appliance is docker
 --ami-image                      Pass PMM server ami image name
 --key-name                       Pass your aws access key file name
 --ova-image                      Pass PMM server ova image name
 --compare-query-count            This will help us to compare the query count between PMM client instance and PMM QAN/Metrics page
```

__Initialize PMM server__

This framework will support all three PMM server appliances using _--pmm-server=[docker|ami|ova]_. Default PMM server appliance is docker

```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --setup
Would you like to enable SSL encryption to protect PMM from unauthorized access[y/n] ? n

Initiating PMM configuration
8475e7a88f6fd1018bab74dcdc5a3026dd02f923be3b4d369d0f15e66c6dc538
0cc9c6fa57a5ad6f48aa9c4c2a15055b7bfb53c80abc531771abd9084e344441
Initiating PMM client configuration
OK, PMM server is alive.

PMM Server      | 10.10.6.203
Client Name     | qaserver-03
Client Address  | 10.10.6.203
******************************************************************
Please execute below command to access docker container
docker exec -it pmm-server bash

PMM landing page               http://10.10.6.203
Query Analytics (QAN web app)  http://10.10.6.203/qan
Metrics Monitor (Grafana)      http://10.10.6.203/graph
Metrics Monitor username       admin
Metrics Monitor password       admin
Orchestrator                   http://10.10.6.203/orchestrator
******************************************************************
ramesh@qaserver-03:~/pmmwork$

ramesh@qaserver-03:~/pmmwork$ sudo docker ps
CONTAINER ID        IMAGE                      COMMAND                CREATED             STATUS              PORTS                         NAMES
0cc9c6fa57a5        percona/pmm-server:1.2.0   "/opt/entrypoint.sh"   8 minutes ago       Up 8 minutes        0.0.0.0:80->80/tcp, 443/tcp   pmm-server
ramesh@qaserver-03:~/pmmwork$
```

__Configure client instances to PMM server__

With _--addclient_ option we can add multiple client instances to PMM server. Currently, the framework supports Percona Server, Percona XtraDB Cluster, MySQL, MariaDB and MongoDB instances.

PS: Client instance should be in binary tarball format. Make sure to download binary tarballs in your work directory before configuring client instances.

You can also use _--download_ option to download binary tar ball from respective location. Also use _--[ps|ms|md|pxc|mo]-version_ to get specific client instance version.

```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --addclient=ps,2 --addclient=ms,2
User 'admin' is already present in MySQL server. Please create Orchestrator user manually.
[linux:metrics] OK, now monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Orchestrator username :  admin
Orchestrator password :  passw0rd
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/PS_NODE_2.sock)
User 'admin' is already present in MySQL server. Please create Orchestrator user manually.
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/MS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/MS_NODE_1.sock)
User 'admin' is already present in MySQL server. Please create Orchestrator user manually.
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/MS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/MS_NODE_2.sock)
ramesh@qaserver-03:~/pmmwork$
```
__Compare query count__

Using _--compare-query-count_ we can compare the query count between PMM client instance and PMM QAN/Metrics page. This option will compare query from both query sources performance schema and slowlog.

```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --addclient=ps,1 --compare-query-count
WARNING! Another mysqld process using /tmp/PS_NODE_1.sock
[linux:metrics] OK, now monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Initializing query count testing
Running first set INSERT statement execution
Sleeping 60 secs
INSERT INTO test.t1 .. query count between 2017-08-09 04:21:52 and 2017-08-09 04:22:14
+-------------------------------------------------+-----------------+-------------------------+
| QUERY                                           | ALL_QUERY_COUNT | QUERY_COUNT_CURRENT_RUN |
+-------------------------------------------------+-----------------+-------------------------+
| INSERT INTO `test` . `t1` ( `str` ) VALUES (?)  |             464 |                     464 |
+-------------------------------------------------+-----------------+-------------------------+
Running second set INSERT statement execution
Sleeping 60 secs
INSERT INTO test.t1 .. query count between 2017-08-09 04:21:52 and 2017-08-09 04:23:27
+-------------------------------------------------+-----------------+-------------------------+
| QUERY                                           | ALL_QUERY_COUNT | QUERY_COUNT_CURRENT_RUN |
+-------------------------------------------------+-----------------+-------------------------+
| INSERT INTO `test` . `t1` ( `str` ) VALUES (?)  |             734 |                     270 |
+-------------------------------------------------+-----------------+-------------------------+
Running third set INSERT statement execution
Sleeping 60 secs
INSERT INTO test.t1 .. query count between 2017-08-09 04:21:52 and 2017-08-09 04:25:07
+-------------------------------------------------+-----------------+-------------------------+
| QUERY                                           | ALL_QUERY_COUNT | QUERY_COUNT_CURRENT_RUN |
+-------------------------------------------------+-----------------+-------------------------+
| INSERT INTO `test` . `t1` ( `str` ) VALUES (?)  |            1510 |                     776 |
+-------------------------------------------------+-----------------+-------------------------+
Running fourth set INSERT statement execution
Sleeping 60 secs
INSERT INTO test.t1 .. query count between 2017-08-09 04:21:52 and 2017-08-09 04:26:45
+-------------------------------------------------+-----------------+-------------------------+
| QUERY                                           | ALL_QUERY_COUNT | QUERY_COUNT_CURRENT_RUN |
+-------------------------------------------------+-----------------+-------------------------+
| INSERT INTO `test` . `t1` ( `str` ) VALUES (?)  |            2301 |                     791 |
+-------------------------------------------------+-----------------+-------------------------+
INSERT INTO test.t1 .. query count from pmm client instance PS_NODE-1 (Performance Schema).
+------------------+
| sum(query_count) |
+------------------+
|             2129 |
+------------------+
INSERT INTO test.t1 .. query count from pmm client instance SHADOW_NODE (Slow log).
+------------------+
| sum(query_count) |
+------------------+
|             2700 |
+------------------+
Please compare these query count with QAN/Metrics webpage
ramesh@qaserver-03:~/pmmwork$
```

__Use _--list_ to view all PMM clients instance__

```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --list
pmm-admin 1.2.0

PMM Server      | 10.10.6.203
Client Name     | qaserver-03
Client Address  | 10.10.6.203
Service Manager | linux-systemd

-------------- ---------- ----------- -------- ----------------------------------- ---------------------------------------------
SERVICE TYPE   NAME       LOCAL PORT  RUNNING  DATA SOURCE                         OPTIONS                                
-------------- ---------- ----------- -------- ----------------------------------- ---------------------------------------------
mysql:queries  PS_NODE-2  -           YES      root:***@unix(/tmp/PS_NODE_2.sock)  query_source=perfschema, query_examples=true
mysql:queries  MS_NODE-1  -           YES      root:***@unix(/tmp/MS_NODE_1.sock)  query_source=perfschema, query_examples=true
mysql:queries  MS_NODE-2  -           YES      root:***@unix(/tmp/MS_NODE_2.sock)  query_source=perfschema, query_examples=true
mysql:queries  PS_NODE-1  -           YES      root:***@unix(/tmp/PS_NODE_1.sock)  query_source=perfschema, query_examples=true
linux:metrics  PS_NODE-1  42000       YES      -                                                                          
mysql:metrics  PS_NODE-1  42002       YES      root:***@unix(/tmp/PS_NODE_1.sock)                                         
mysql:metrics  PS_NODE-2  42003       YES      root:***@unix(/tmp/PS_NODE_2.sock)                                         
mysql:metrics  MS_NODE-1  42004       YES      root:***@unix(/tmp/MS_NODE_1.sock)                                         
mysql:metrics  MS_NODE-2  42005       YES      root:***@unix(/tmp/MS_NODE_2.sock)                                         

ramesh@qaserver-03:~/pmmwork$
```
__Clean framework configuration__

 i) _--wipe-clients_ 
 This will stop all client instances and remove all clients from pmm-admin
 ```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --wipe-clients
Shutting down mysql instance (--socket=/tmp/PS_NODE_2.sock)
Shutting down mysql instance (--socket=/tmp/PS_NODE_1.sock)
Shutting down mysql instance (--socket=/tmp/MS_NODE_2.sock)
Shutting down mysql instance (--socket=/tmp/MS_NODE_1.sock)
Removing all local pmm client instances
ramesh@qaserver-03:~/pmmwork$
```
 
ii) _--wipe-server_
 This will stop pmm-server container and remove all pmm containers
```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --wipe-server
Removing pmm-server docker containers
ramesh@qaserver-03:~/pmmwork$
```

iii) _--wipe_
 This will wipe all pmm configuration
 
 ```
ramesh@qaserver-03:~/pmmwork$ ~/percona-qa/pmm-tests/pmm-framework.sh --wipe
Shutting down mysql instance (--socket=/tmp/PS_NODE_2.sock)
Shutting down mysql instance (--socket=/tmp/PS_NODE_1.sock)
Shutting down mysql instance (--socket=/tmp/MS_NODE_2.sock)
Shutting down mysql instance (--socket=/tmp/MS_NODE_1.sock)
Removing all local pmm client instances
Removing pmm-client instances from docker containers
Removing pmm-client docker containers
Removing pmm-server docker containers
ramesh@qaserver-03:~/pmmwork$
 ```
