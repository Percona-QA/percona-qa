# Created by Shahriyar Rzayev from Percona

# Bats tests for generated columns with MyRocks.

# Will be passed from myrocks-testsuite.sh
DIRNAME=$1
BASEDIR=$2

function execute_sql() {
  # General function to pass sql statement to mysql client
   ${DIRNAME}/${BASEDIR}/cl -e "$1"
}

@test "Adding virtual generated column" {
  result=execute_sql "alter table generated_columns_test.sbtest1 add column json_test_v json generated always as (json_array(k,c,pad)) virtual;"
}
