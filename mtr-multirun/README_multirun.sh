I apologize in advance for this rudimentary description and
any "misbehavior" of MULTIRUN.sh at runtime.

WARNING
-------
MULTIRUN.sh
- is without any warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE
- is nothing else than a proof of concept prototype under construction
- has quite annoying runtime properties (extreme load) caused by its purpose

Given its small age, non frequent use and fragmentary QA it got I expect that it will fail
under certain currently not yet known conditions (tests with complex structure, mean location
of files to be sourced and similar) because of internal errors.


Main purpose of MULTIRUN.sh
---------------------------
Certain tests tend to show up with sporadic failures.
This happens
- usually in runs on boxes with automatic release build and testing
- rather rare on the boxes where developers work.
Some prominent reason for such sporadic fails is an unfortunate combination of
- properties of test/sensitivity to timing effects caused by parallel load
and
- power of hardware+OS
and
- greedy setup of test running in parallel (imagine ./mtr --parallel=<high value>)
Fixing that by changing the vulnerable test is frequent the best solution.

Checking if some new or modified test tends to sporadic failures before pushing it
to some repository would be even better.

MULTIRUN.sh checks if some test tends to sporadic fails by generating some high artifical
CPU and IO load. So some test developer could simulate the harsh conditions on some build+test
box even on some notebook.
And that should lead to faster
   "try to make some test less vulnerable by modifying its code"
   "check if that is really an improvement"
cycles.


How to use MULTIRUN.sh?
-----------------------
Just place MULTIRUN.sh whereever you want.

cd <tree with binaries>/mysql-test
Please check that at least a
   ./mysql-test-run.pl <additional MTR options> --suite=<suite> <test>
passes.

<wherever MULTIRUN.sh is placed>/MULTIRUN.sh <absolute or relative path to test> <type of test> <additional MTR options>


Example from my box
-------------------
/home/user/bin/MULTIRUN.sh        -- directory where I placed MULTIRUN.sh
                                       My $PATH contains '/home/user/bin'.
/home/user/Server                 -- location of my MariaDB source trees
/home/user/Server/10.4            -- top level directory of my 10.4 source tree
/home/user/Server/10.4/mysql-test -- place of the MTR based tests within the 10.4 source tree
/home/user/Server/10.4/bld_debug  -- directory with my binaries build with debug of 10.4

cd /home/user/Server/10.4/bld_debug/mysql-test
MULTIRUN.sh /home/user/Server/10.4/mysql-test/main/1st.test cpu
    alternative
MULTIRUN.sh ../../mysql-test/main/1st.test cpu


Some hints regarding the behaviour of MULTIRUN.sh at runtime
------------------------------------------------------------
1. Use a box with low power
      Good example: some ~ 7 years old notebook with modern OS
   for MULTIRUN.sh runs and rather not some high end box.
   Disadvantages of the latter:
   - Maybe trouble (inside MULTIRUN.sh) to achieve the required load
   - Maybe hit OS/user limits
   - Neither the elapsed runtime for
     - try to fix the test and than check impact
     nor for
     - check if some test tends to sporadic fails
     will shrink with more powerful hardware.
2. Caused by its purpose MULTIRUN.sh will create some extreme load on your box.
   Parallel editing of files should be fast enough.
   But chatting, surfing in web etc. might be non acceptable slow.
3. Do not run other tests in parallel. There might be clashes between these tests.
4. The most safe (mean against errors inside MULTIRUN.sh) environment is some
   "in source build".

In case you want to stop the ongoing MULTIRUN.sh run than please be aware that the
load generators running in background are serious more delicate and annoying than
the mysqltest/mysqld processes.
Please try first
   CTRL-C and waiting lets say 10s
The load_generators should trap that and stop their work.
Only in case this does not work satisfying than start to kill processes manual.
Please try to kill the load_generator processes first.


Regards,

Matthias 2019-01-22

