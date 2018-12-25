#!/usr/bin/env bats

###########################################################
# Created By Manish Chawla, Percona LLC                   #
# This script is a test wrapper for ps-upgrade-test_v1.sh #
# Assumption: Bats framework is already installed         #
# Usage:                                                  #
# 1. Create a Workdir for upgrade                         #
# 2. Copy the Lower PS dir and Upper PS dir to Workdir    #
# 3. Set paths in this script:                            #
#    Scriptdir, Workdir, Lower_PS_dir, Upper_PS_dir       #
# 4. Run the script simply as: ./ps_upgrade_tests.bat     #
# 5. Logs for test run are available in: Workdir          #
###########################################################
 
export Scriptdir="$HOME/percona-qa"
export Workdir="$HOME/upgrade"
export Lower_PS_dir="$HOME/upgrade/percona-server-5.7.23-23-linux-x86_64"
export Upper_PS_dir="$HOME/upgrade/percona-server-8.0.13-2-linux-x86_64"

@test "Running upgrade for partitioned tables" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t partition_test
  [ "$status" -eq 0 ]
}

@test "Running upgrade for non-partitioned tables" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t non_partition_test
  [ "$status" -eq 0 ]
}

@test "Running upgrade for compressed tables" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t compression_test
  [ "$status" -eq 0 ]
}

@test "Running upgrade for --innodb_file_per_table=ON" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t innodb_options_test -o --innodb_file_per_table=ON
  [ "$status" -eq 0 ]
}

@test "Running upgrade for --innodb_file_per_table=OFF" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t innodb_options_test -o --innodb_file_per_table=OFF
  [ "$status" -eq 0 ]
}

@test "Running upgrade for replication with gtid" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t replication_test_gtid
  [ "$status" -eq 0 ]
}

@test "Running upgrade for replication with mts" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t replication_test_mts
  [ "$status" -eq 0 ]
}

@test "Running upgrade for replication without gtid" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t replication_test
  [ "$status" -eq 0 ]
}

@test "Running upgrade for replication with encryption and gtid" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t replication_test_gtid -e -k file
  [ "$status" -eq 0 ]
}

@test "Running upgrade for replication with encryption and mts" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t replication_test_mts -e -k file
  [ "$status" -eq 0 ]
}

@test "Running upgrade for replication with encryption and without gtid" {
  run $Scriptdir/ps-upgrade-test_v1.sh -w $Workdir -l $Lower_PS_dir -u $Upper_PS_dir -t replication_test -e -k file
  [ "$status" -eq 0 ]
}
