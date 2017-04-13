#!/usr/bin/env bats
load test_helper


@test "run pmm-admin remove all mysql metrics" {
run sudo pmm-admin remove --all
echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[0]}" |grep  "OK"
}

@test "run pmm-admin add mysql" {
run sudo pmm-admin add mysql
echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[0]}" |grep  "OK"
}

@test "stop PMM server" {
run sudo docker stop pmm-server
echo "$output"
  [ "$status" -eq 0 ]
}

@test "run pmm-admin restart --all" {
run sudo pmm-admin restart --all
echo "$output"
  [ "$status" -eq 0 ]
  echo  "${lines[0]}" |grep  "OK, restarted "
}

@test "start PMM server" {
run sudo docker start pmm-server
echo "$output"
  [ "$status" -eq 0 ]
}
