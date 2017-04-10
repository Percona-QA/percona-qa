#!/usr/bin/env bats
load test_helper

PATH_TO_CONF="/usr/local/percona/pmm-client/pmm.yml"

@test "run pmm-admin add mysql with default user" {
run sudo pmm-admin add mysql

echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[2]}" |grep  "OK, now monitoring MySQL queries from slowlog using DSN root" 
}

@test "check mysql_password wasnt added to pmm.yml" {
  run bash -c "sudo /bin/cat ${PATH_TO_CONF}  |grep mysql_password"
  assert_fail
}

@test "run pmm-admin remove all mysql metrics" {
run sudo pmm-admin remove mysql
echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[0]}" |grep  "OK"
}


@test "run pmm-admin add mysql with pmm user" {
run sudo pmm-admin add mysql --create-user --force

echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[2]}" |grep  "OK, now monitoring MySQL queries from slowlog using DSN pmm"
}

@test "check mysql_password was added to pmm.yml" {
  run bash -c "sudo /bin/cat ${PATH_TO_CONF}  |grep mysql_password"
  assert_success
}

@test "run pmm-admin remove mysql metrics" {
run sudo pmm-admin rm mysql
echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[0]}" |grep  "OK"
}

@test "check mysql_password removed from pmm.yml" {
  run bash -c "sudo /bin/cat /usr/local/percona/pmm-client/pmm.yml  |grep mysql_password"
  assert_fail
}


