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
get_databases.sh
drop_databases.sh
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
  --wipe_setup                    Remove test database and tables from
                                  physical instances
  --cycle INTEGER                 Run tests in a cycle
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
* Wiping clients before each test run if specified(--wipe_clients) == pmm-framework.sh --wipe-clients
* Dropping test databases from physical instances(--wipe_setup)
* Running tests in a cycle(--cycle)

```
Percona_Servers]$ python ~/percona-qa/pmm-tests/pmm_stress_test_py/randomized_instances.py  \
--instance_type ps --instance_count 1 --pmm_instance_count 2 --create_databases 10 \
--create_tables 10 --create_sleep_queries 20 ps 10 --create_unique_queries 20 \
--insert_blobs 2 --insert_longtexts 2 10000 --cycle 4 \
 --wipe_setup --wipe_clients

 Removing all local pmm client instances
 User 'admin' is already present in MySQL server. Please create Orchestrator user manually.
 [linux:metrics] OK, now monitoring this system.
 [mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
 [mysql:queries] OK, now monitoring MySQL queries from perfschema using DSN root:***@unix(/tmp/PS_NODE_1.sock)
 Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=36538 cea62db2-f26e-4bef-a864-d2c33f2cd8fc
 [linux:metrics] OK, already monitoring this system.
 [mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
 [mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
 Running -> sudo pmm-admin add mysql --user=root --socket=/tmp/PS_NODE_1.sock --service-port=22542 417738ec-cb5c-4539-9601-c6e4f47d0e65
 [linux:metrics] OK, already monitoring this system.
 [mysql:metrics] OK, now monitoring MySQL metrics using DSN root:***@unix(/tmp/PS_NODE_1.sock)
 [mysql:queries] OK, now monitoring MySQL queries from slowlog using DSN root:***@unix(/tmp/PS_NODE_1.sock)
 Starting cycle 1
 Creating databases using MYSQL_SOCK=/tmp/PS_NODE_1.sock
 Creating tables using MYSQL_SOCK=/tmp/PS_NODE_1.sock
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
 MYSQL_SOCK=/tmp/PS_NODE_1.sock
 Benchmark
 	Average number of seconds to run all queries: 0.526 seconds
 	Minimum number of seconds to run all queries: 0.526 seconds
 	Maximum number of seconds to run all queries: 0.526 seconds
 	Number of clients running queries: 1
 	Average number of queries per client: 20

 Create database using MYSQL_SOCK=/tmp/PS_NODE_1.sock
 Create table using MYSQL_SOCK=/tmp/PS_NODE_1.sock
 Inserting image into table
 Inserting image into table
 Create database using MYSQL_SOCK=/tmp/PS_NODE_1.sock
 Create table using MYSQL_SOCK=/tmp/PS_NODE_1.sock
 Inserting long text into table
 Inserting long text into table
 Cleaning cycle 1
```
