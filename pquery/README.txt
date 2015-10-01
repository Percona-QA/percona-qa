To execute pquery, use pquery-run.sh in parent folder (percona-qa). 

The run1/run2/run3 scripts in this directory are simple examples of how to do a single trial run. OTOH, pquery-run.sh executes pquery runs consecutively. 

In RQG comparitative terms, run1 may be compared with gentest.pl (i.e. a started mysqld is necessary), whilst pquery-run.sh may be compared with "middle grounds" between runall.pl and combinations.pl. i.e. it starts mysqld but it does not run multi-threaded (i.e. no --parallel=x equivalent) yet. Number of clients per mysqld (i.e. --threads equivalent) can be multi-threaded (THREADS=y) however.

Nonetheless, pquery-run.sh is able to generate hundreds of crashes in the space of a few hours. Once this is exhausted, multi-threaded support for pquery-run.sh becomes interesting.

Also see other pquery-*.sh sripts in parent folder for easy handling/processing of pquery-run.sh generated trials.

Please edit pquery-run.sh (set BASEDIR directory) before starting it.
