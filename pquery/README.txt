To execute pquery, use pquery-run.sh in parent folder (percona-qa). 

The run1/run2/run3 scripts in this directory are simple examples of how to do a single trial run. OTOH, pquery-run.sh executes pquery runs consecutively. 

In RQG comparitative terms, run1 may be compared with gentest.pl (i.e. a started mysqld is necessary), whilst pquery-run.sh is a combinarion of runall.pl and combinations.pl

pquery-run.sh is able to generate hundreds of crashes in the space of a few hours. So called 'screenfillers' (use pquery-prep-red.sh and then pquery-clean-known.sh and finally pquery-results.sh) are clear regressions/issues in a build (if the filter lists - ref known_issues.strings) have been kept updated.

Also see other pquery-*.sh sripts in parent folder for easy handling/processing of pquery-run.sh generated trials.

Please edit pquery-run.sh (set BASEDIR directory etc.) before starting it.
