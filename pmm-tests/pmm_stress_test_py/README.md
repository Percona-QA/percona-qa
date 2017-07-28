# Welcome to PMM Stress Test Python land.

This tool is designed to run separately from daily life testing.
But it can be used with low values to check some functionalities.
  > Script should be called from PS/PXC tarball folder.

The project structure:
```
pmm_stress_test_py/randomized_instances.py --> Main caller Python script.
requirements.txt                           --> Package dependency list.
pmm_stress_test_py_tests/test_module01.py  --> PyTests for script.
```

I have created several bash scripts as helper for this tool.
These bash scripts are callable as separate scripts, so it can be used further.
Supplementary or helper scripts:
```
create_blob_img.sh                        
create_database.sh                        
create_longtext.sh                        
create_sleep_queries.sh
create_table.sh
create_unique_queries.sh
```

## Installation
Basically the only thing we need to get started, is to install dependency packages.
Run the following command:

```
pip install -r requirements.txt
```

## Options
```
$ python ~/percona-qa/pmm-tests/pmm_stress_test_py/randomized_instances.py --help
Usage: randomized_instances.py [OPTIONS]

Options:
  --version                       Version information.
  --threads INTEGER               Give non-zero number to enable multi-thread
                                  run!
  --instance_type TEXT            Passing instance type(ps, ms, md, pxc, mo)
                                  to pmm-framework.sh  [required]
  --instance_count INTEGER        How many physical instances you want to
                                  start? (Passing to pmm-framework.sh)
                                  [required]
  --pmm_instance_count INTEGER    How many pmm instances you want to add with
                                  randomized names from each physical
                                  instance? (Passing to pmm-admin)  [required]
  --create_databases INTEGER      How many databases to create per added
                                  instance for stress test?
  --create_tables INTEGER         How many tables to create per added instance
                                  for stress test?
  --create_sleep_queries TEXT...  How many 'select sleep()' queries to run?
                                  1->query count, 2->instance type, 3->thread
                                  count
  --create_unique_queries INTEGER
                                  How many unique queries to create and run
                                  against added instances?
  --insert_blobs INTEGER          How many times to insert test binary image
                                  into demo table?
  --insert_longtexts INTEGER...   Multiple value option, 1->number of inserts,
                                  2->the length of string to generate
  --wipe_clients                  Remove/wipe pmm instances if specified
  --help                          Show this message and exit.
```


## Sample run
This run is doing following things:
* Starting 2 physical PS instances(--instance_type ps --instance_count 2) and adding them to PMM
* Generating 10 randomized instances(--pmm_instance_count 10) for each PS instances(for us 2) and adding them to PMM, totally 20 pmm instances
* Creating 10 databases(--create_databases 10)
* Creating 10 tables (--create_tables 10)
* Creating 20 sleep queries for giving instance type(ps) and inserting them using 10 Python threads(--create_sleep_queries 20 ps 10)
* Creating 20 unique queries(-create_unique_queries 20) using mysqlslap and running it against each PS instance.
* Creating raw image with and inserting it 2 times into table (--insert_blobs 2)
* Creating string with given length(10000) and inserting it 2 times (--insert_longtexts 2 10000)
* Wiping clients before each test run if specified(--wipe_clients)

```
Percona_Servers]$ python ~/percona-qa/pmm-tests/pmm_stress_test_py/randomized_instances.py  \
--instance_type ps --instance_count 2 --pmm_instance_count 10 --create_databases 10 \
--create_tables 10 --create_sleep_queries 20 ps 10 --create_unique_queries 20 \
--insert_blobs 2 --insert_longtexts 2 10000 --wipe_clients
No services under pmm monitoring
Orchestrator username :  admin
Orchestrator password :  passw0rd
[linux:metrics] OK, now monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Orchestrator username :  admin
Orchestrator password :  passw0rd
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=43618 d4028fad-9bd6-4fe9-a840-f776879f6377
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=24022 7938d2f0-47fd-43e6-b403-67e3846ead6e
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=12447 ec1177a4-e07b-4308-a105-82b2617bc3f0
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=58882 970904bb-a6b0-4b32-a8bf-0522fb9f280d
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=56477 d490ba9d-1cb9-4531-849d-23c5d544a89f
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=53564 1b2012a4-452e-4345-9174-af5de585fee6
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=40146 8b527939-4d70-4096-905f-13af4617363b
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=29243 856aa850-be5e-495b-bc91-f41ba573c960
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=29192 462b1f31-9fc0-43c4-b164-2b5a525df65e
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=54043 c3f0b202-814a-433a-a34e-74bb8bd6dacc
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=33272 ab152916-36b3-48f7-856b-6df6e25e6050
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=31609 001c6af1-0dd6-44c5-8e63-1df8ca875382
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=23891 7594b8a2-ce4c-4188-9805-b9639718f28e
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=28666 be7caf06-471f-4a1a-a6a2-32cb2d7ffb8d
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=21119 ad1c2d3e-2412-4e76-96c2-1d99b65d1b91
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=26410 a764db12-be05-427d-a1e9-fb93f67128b9
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=57810 66250435-12af-4725-94e9-e46dec22020d
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=19745 84ffab0d-7dd1-4ad2-9ed5-a8c478f64de1
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=30116 eb6da508-7691-40ae-9526-2d5a07a77c98
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_2.sock --service-port=23497 e1177cba-91ab-476d-a83b-bc48c1fe6726
[linux:metrics] OK, already monitoring this system.
[mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_2.sock)
[mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_2.sock)
Creating databases using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating databases using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating tables using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating tables using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Creating sleep() queries using MYSQL_SOCK=/tmp/PS_NODE_2.sock
(py_2.7_pmm)[shahriyar.rzaev@qaserver-02 Percona_Servers]$ Create database using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Create database using MYSQL_SOCK=/tmp/PS_NODE_1.sock
MYSQL_SOCK=/tmp/PS_NODE_1.sock
Create table using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Create table using MYSQL_SOCK=/tmp/PS_NODE_1.sock
Inserting long text into table
Inserting image into table
Inserting long text into table
Inserting image into table
Create database using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Create database using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Create table using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Create table using MYSQL_SOCK=/tmp/PS_NODE_2.sock
Inserting image into table
Inserting long text into table
Inserting image into table
Inserting long text into table
Benchmark
	Average number of seconds to run all queries: 2.443 seconds
	Minimum number of seconds to run all queries: 2.443 seconds
	Maximum number of seconds to run all queries: 2.443 seconds
	Number of clients running queries: 1
	Average number of queries per client: 20

MYSQL_SOCK=/tmp/PS_NODE_2.sock
Benchmark
	Average number of seconds to run all queries: 1.785 seconds
	Minimum number of seconds to run all queries: 1.785 seconds
	Maximum number of seconds to run all queries: 1.785 seconds
	Number of clients running queries: 1
	Average number of queries per client: 20
```
